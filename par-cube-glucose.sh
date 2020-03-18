#!/bin/bash

DEPTH=5

UNK=UNKNOWN
TRUE=1

log "c split depth "$DEPTH

if [ -z "$1" ]
then
  CNF=/CnC/formula.cnf
  aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} $CNF
  DIR=/CnC
else
  CNF=$1
  DIR=.
fi

# check if input file exists, otherwise terminate
if [ ! -f "$CNF" ]; then echo "c ERROR formula does not exit"; exit 1; fi

NCLS=`head -n 1000 $CNF | grep "p cnf" | awk '{print $4}'`
if [ "$NCLS" -gt "1000000" ]; then echo "c WARNING formula has over a million clauses\n"; exit 1; fi

PAR=${NUM_PROCESSES}
OUT=/tmp

# if PAR not defined, then assume the script runs locally (for testing)
if [ -z "$PAR" ]; then PAR=4; fi

echo "c running "$PAR" threads"

log () {
  echo "${BASENAME} - ${1}"
}
HOST_FILE_PATH="/tmp/hostfile"

# set child by default and switch to main if on main node container
NODE_TYPE="child"
if [ "${AWS_BATCH_JOB_MAIN_NODE_INDEX}" == "${AWS_BATCH_JOB_NODE_INDEX}" ]; then
  log "c running synchronize as the main node"
  NODE_TYPE="main"
fi

/usr/sbin/sshd -D &

# wait for all nodes to report
wait_for_nodes () {
  log "c running as master node"

  touch $HOST_FILE_PATH-0
  IP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  MAXCORES=$(nproc)
  log "c master details -> $IP:$MAXCORES"
  echo "$IP slots=$MAXCORES" >> $HOST_FILE_PATH-0
  OLD=0
  LINES=$(ls -dq /tmp/hostfile* | wc -l)
  while [ "${AWS_BATCH_JOB_NUM_NODES}" -gt "${LINES}" ]
  do
    LINES=$(ls -dq /tmp/hostfile* | wc -l)
    if [ "$OLD" -ne "$LINES" ]; then
      log "c $LINES out of $AWS_BATCH_JOB_NUM_NODES nodes joined";
      OLD=$LINES;
    fi
    sleep 1
  done

  $DIR/cadical/build/cadical $CNF -c 100000 -o $OUT/simp.cnf -q > $OUT/simp-result.txt
  RES=`cat $OUT/simp-result.txt | grep "^s " | awk '{print $2}'`
  if [ "$RES" == "UNKNOWN" ]; then
    cat $OUT/simp-result.txt
    exit $!
  else
    log "CaDiCaL simplified the formula"
  fi
  log "orignial formula"
  head $CNF | grep "cnf"
  log "simplified formula"
  head $OUT/simp.cnf | grep "cnf"
#  SPLIT=${AWS_BATCH_JOB_NUM_NODES}
  SPLIT=$((${AWS_BATCH_JOB_NUM_NODES} * $PAR))
  $DIR/march_cu/march_cu $OUT/simp.cnf -o $OUT/cubes-main-$$.txt -d 10 -l $SPLIT

  for (( NODE=0; NODE<${AWS_BATCH_JOB_NUM_NODES}; NODE++ ))
  do
    awk 'NR % '${AWS_BATCH_JOB_NUM_NODES}' == '$NODE'' $OUT/cubes-main-$$.txt > $OUT/cubes-split-$NODE.txt
#    cat $OUT/cubes-split-$NODE.txt
    log "copying cube file to node "$NODE
    NODE_IP=$(cat $HOST_FILE_PATH-$NODE | awk '{print $1}')
    echo "c copying cubes-split-"$NODE".txt to "$NODE_IP
    scp $OUT/cubes-split-$NODE.txt $NODE_IP:/CnC/cubes-split-$NODE.txt
  done
}

report_to_master () {
  IP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  MAXCORES=$(nproc)

  log "c I am a child node -> $IP:$MAXCORES, reporting to the master node -> ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}"

  echo "$IP slots=$MAXCORES" >> $HOST_FILE_PATH-${AWS_BATCH_JOB_NODE_INDEX}
  ping -c 3 ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}
  until scp $HOST_FILE_PATH-${AWS_BATCH_JOB_NODE_INDEX} ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:$HOST_FILE_PATH-${AWS_BATCH_JOB_NODE_INDEX}
  do
    echo "c master not reachable yet, sleeping 1 second and trying again"
    sleep 1
  done
  log "c done! goodbye"
  ps -ef | grep sshd
}

log $NODE_TYPE
case $NODE_TYPE in
  main)
    wait_for_nodes "${@}"
    ;;

  child)
    report_to_master "${@}"
    ;;

  *)
    log $NODE_TYPE
    usage "c ERROR: could not determine node type. Expected (main/child)"
    ;;
esac

while [ ! -f /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt ]
do
  ls /CnC/cubes-split-* 2> /dev/null
  echo "c waiting for cube file to appear, sleep 1 second"
  sleep 1
done
echo "Okay let's run!"

rm -f $OUT/output*.txt
rm -f $OUT/pids.txt
touch $OUT/output.txt
touch $OUT/pids.txt

LINES=`wc /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt | awk '{print $1}'`
MIN=$(( $PAR < $LINES ? $PAR : $LINES ))

log "local cubes "$LINES" "$MIN
chmod 644 /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt
cat /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt

##### simplify all subformulas in parallel ######
for (( CORE=1; CORE<=$MIN; CORE++ ))
do
  /CnC/scripts/apply.sh $CNF /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt $CORE > $OUT/node-$CORE.cnf
  $DIR/cadical/build/cadical $OUT/node-$CORE.cnf -c 100000 -o $OUT/simp-$CORE.cnf -q > $OUT/simp-result-$CORE.txt &
  PIDS[$CORE]=$!
  log "simplifying subformula "$CORE" on process "$!
done

# wait for all pids
for (( CORE=1; CORE<=$MIN; CORE++ )) do wait ${PIDS[$CORE]}; done

##### partition all simplied subformulas in parallel ######
JOBS=0
for (( CORE=1; CORE<=$MIN; CORE++ ))
do
  echo "a 0" > $OUT/cubes-$CORE.txt
  echo -n "c subformula result on core "$CORE": "; cat $OUT/simp-result-$CORE.txt
  RES=`cat $OUT/simp-result-$CORE.txt | grep -e "SATIS" -e "UNKNOWN" | awk '{print $2}'`
  if [ "$RES" == "$UNK" ]; then
    JOBS=$(($JOBS + 1))
    $DIR/march_cu/march_cu $OUT/simp-$CORE.cnf -o $OUT/cubes-$CORE.txt -d $DEPTH &
    PIDS[$JOBS]=$!
    log "partitioning simplified subformula "$CORE" on process "$!
  fi
done

# wait for all pids
for (( CORE=1; CORE<=$JOBS; CORE++ )) do wait ${PIDS[$CORE]}; done

 ##### merge all cubes and clean up #####
for (( CORE=1; CORE<=$MIN; CORE++ ))
do
  /CnC/scripts/prefix.sh /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt $CORE $OUT/cubes-$CORE.txt >> $OUT/cubes-merge-$$.txt
  rm $OUT/node-$CORE.cnf $OUT/simp-result-$CORE.txt $OUT/simp-$CORE.cnf
done

NCBS=`wc $OUT/cubes-merge-$$.txt | awk '{print $1}'`
log "total number of local cubes "$NCBS



kill_threads() {
  log "c killing the remaining open threads"
  for ID in `cat $OUT/pids.txt`; do echo "c killing thread "$ID; kill $ID 2> /dev/null; done
}

OLD=-1
FLAG=1
while [ "$FLAG" == "1" ]
do
  SAT=`cat $OUT/output*.txt | grep "^SAT" | awk '{print $1}' | uniq`
  if [ "$SAT" == "SAT" ]; then echo "c DONE: ONE JOB SAT"; kill_threads "${@}"; FLAG=0; fi

  SAT=`cat CnC/summary*.txt 2> /dev/null | grep "^SAT" | awk '{print $1}' | uniq`
  if [ "$SAT" == "SAT" ]; then echo "c DONE: ONE NODE SAT"; kill_threads "${@}"; FLAG=0; fi

  UNSAT=`cat $OUT/output*.txt | grep "^UNSAT" | wc | awk '{print $1}'`
  if [ "$OLD" -ne "$UNSAT" ]; then echo; echo "c local progress: "$UNSAT" UNSAT out of "$PAR; OLD=$UNSAT; fi
  if [ "$UNSAT" == "$PAR" ]; then echo "c DONE: ALL JOBS UNSAT"; kill_threads "${@}"; FLAG=0; break; fi
  ALIVE=`ps $$ | wc | awk '{print $1}'`
  if [ "$ALIVE" == "1" ]; then echo "c PARENT TERMINATED"; kill_threads "${@}"; FLAG=0; break; fi
  if [ "$FLAG"  == "1" ]; then sleep 1; fi
done &

for (( CORE=0; CORE<$PAR; CORE++ ))
do
  echo "p inccnf" > $OUT/formula$$-$CORE.icnf
  cat  $CNF | grep -v c >> $OUT/formula$$-$CORE.icnf
#  cat  $LOCAL_CNF | grep -v c >> $OUT/formula$$-$CORE.icnf
  awk  'NR % '$PAR' == '$CORE'' $OUT/cubes-merge-$$.txt >> $OUT/formula$$-$CORE.icnf
  $DIR/iglucose/core/iglucose $OUT/formula$$-$CORE.icnf $OUT/output-$CORE.txt -verb=0 &
  PIDS[$CORE]=$!
  echo "c constructed CNF formula for core "$CORE" on process "$!
  echo ${PIDS[$CORE]} >> $OUT/pids.txt
done

# wait for all pids
for (( CORE=0; CORE<$PAR; CORE++ )) do wait ${PIDS[$CORE]}; done

rm $OUT/cubes-merge-$$.txt
for (( CORE=0; CORE<$PAR; CORE++ ))
do
  rm $OUT/formula$$-$CORE.icnf
done

cat $OUT/output*.txt | grep "SAT" | awk '{print $1}' | sort | uniq -c | tr "\n" "\t" | awk '{print $2" "$1" "$4" "$3}' > /CnC/summary-${AWS_BATCH_JOB_NODE_INDEX}.txt
cat /CnC/summary-${AWS_BATCH_JOB_NODE_INDEX}.txt
scp /CnC/summary-${AWS_BATCH_JOB_NODE_INDEX}.txt ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:/CnC/summary-${AWS_BATCH_JOB_NODE_INDEX}.txt

log "c finished node "${AWS_BATCH_JOB_NODE_INDEX}

wait_for_termination() {
  OLD=-1
  FLAG=1
  while [ "$FLAG" == "1" ]
  do
    SAT=`cat CnC/summary*.txt 2> /dev/null | grep "^SAT" | awk '{print $1}' | uniq`
    if [ "$SAT" == "SAT" ]; then
      echo "SAT" > sat.txt
      echo "c ENDING THE OTHER NODES"; FLAG=0;
      for (( NODE=0; NODE<${AWS_BATCH_JOB_NUM_NODES}; NODE++ ))
      do
        NODE_IP=$(cat $HOST_FILE_PATH-$NODE | awk '{print $1}')
        scp sat.txt $NODE_IP:$OUT/output-X.txt
      done
    fi

    SUM=`ls CnC/summary*.txt 2> /dev/null | wc | awk '{print $1}'`
    if [ "$OLD" -ne "$SUM" ]; then echo; echo "c global progress: "$SUM" nodes finished out of "${AWS_BATCH_JOB_NUM_NODES}; OLD=$SUM; fi
    if [ "$SUM" == "${AWS_BATCH_JOB_NUM_NODES}" ]; then echo "c DONE: ALL NODE TERMINATED"; FLAG=0; break; fi
    if [ "$FLAG" == "1" ]; then sleep 1; fi
  done
  for file in CnC/summary-*.txt;
  do
    echo -n $file" "; cat $file;
  done
}

case $NODE_TYPE in
  main)
    wait_for_termination "${@}"
    ;;

  child)
    log "c finished node "${AWS_BATCH_JOB_NODE_INDEX}
    ;;

  *)
    log $NODE_TYPE
    usage "c ERROR: could not determine node type. Expected (main/child)"
    ;;
esac
