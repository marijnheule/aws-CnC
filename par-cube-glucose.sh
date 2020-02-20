#!/bin/bash

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

PAR=${NUM_PROCESSES}
OUT=/tmp

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
  LINES=$(ls -dq /tmp/hostfile* | wc -l)
  while [ "${AWS_BATCH_JOB_NUM_NODES}" -gt "${LINES}" ]
  do
    cat $HOST_FILE_PATH-0

    LINES=$(ls -dq /tmp/hostfile* | wc -l)
    log "c $LINES out of $AWS_BATCH_JOB_NUM_NODES nodes joined, check again in 1 second"
    sleep 1
  done

  $DIR/march_cu/march_cu $CNF -o $OUT/cubes-$$.txt -d 10 -l ${AWS_BATCH_JOB_NUM_NODES}

  for (( NODE=0; NODE<${AWS_BATCH_JOB_NUM_NODES}; NODE++ ))
  do
    awk 'NR % '${AWS_BATCH_JOB_NUM_NODES}' == '$NODE'' $OUT/cubes-$$.txt > $OUT/cubes-split-$NODE.txt
    cat $OUT/cubes-split-$NODE.txt
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
  ls /CnC/cubes-split-*
  echo "c waiting for cube file to appear, sleep 1 second"
  sleep 1
done
echo "Okay lets run!"

chmod 644 /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt
cat /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt

rm -f $OUT/output*.txt
rm -f $OUT/id.txt
touch $OUT/output.txt
touch $OUT/id.txt

LOCAL_CNF=/CnC/local-formula.cnf
/CnC/scripts/apply.sh $CNF /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt 1 > $LOCAL_CNF
$DIR/march_cu/march_cu $LOCAL_CNF -o $OUT/cubes$$ -d 10

kill_threads() {
  for ID in `cat $OUT/id.txt`; do kill $ID; done
#  for ID in `cat /tmp/id.txt`; do pkill -TERM -P $ID; done
}

OLD=-1
FLAG=1
while [ "$FLAG" == "1" ]
do
  SAT=`cat $OUT/output*.txt | grep "^SAT" | awk '{print $1}' | uniq`
  if [ "$SAT" == "SAT" ]; then echo "c DONE: ONE JOB SAT"; kill_threads "${@}"; FLAG=0; fi

  SAT=`cat CnC/summary*.txt | grep "^SAT" | awk '{print $1}' | uniq`
  if [ "$SAT" == "SAT" ]; then echo "c DONE: ONE NODE SAT"; kill_threads "${@}"; FLAG=0; fi

  UNSAT=`cat $OUT/output*.txt | grep "^UNSAT" | wc | awk '{print $1}'`
  if [ "$OLD" -ne "$UNSAT" ]; then echo; echo "c progress: "$UNSAT" UNSAT out of "$PAR; OLD=$UNSAT; fi
  if [ "$UNSAT" == "$PAR" ]; then echo "c DONE: ALL JOBS UNSAT"; kill_threads "${@}"; FLAG=0; break; fi
  ALIVE=`ps $$ | wc | awk '{print $1}'`
  if [ "$ALIVE" == "1" ]; then echo "c PARENT TERMINATED"; kill_threads "${@}"; FLAG=0; break; fi
  if [ "$FLAG"  == "1" ]; then sleep 1; fi
done &

for (( CORE=0; CORE<$PAR; CORE++ ))
do
  echo "p inccnf" > $OUT/formula$$-$CORE.icnf
  cat $LOCAL_CNF | grep -v c >> $OUT/formula$$-$CORE.icnf
  awk 'NR % '$PAR' == '$CORE'' $OUT/cubes$$ >> $OUT/formula$$-$CORE.icnf
  $DIR/iglucose/core/iglucose $OUT/formula$$-$CORE.icnf $OUT/output-$CORE.txt -verb=0 &
  ID=$!
  echo $ID >> $OUT/id.txt
done
wait

rm $OUT/cubes$$
for (( CORE=0; CORE<$PAR; CORE++ ))
do
  rm $OUT/formula$$-$CORE.icnf
done

cat $OUT/output*.txt | grep "SAT" | awk '{print $1}' | sort | uniq -c | tr "\n" "\t" | awk '{print $2" "$1" "$4" "$3}' > summary-${AWS_BATCH_JOB_NODE_INDEX}.txt
cat summary-${AWS_BATCH_JOB_NODE_INDEX}.txt
scp summary-${AWS_BATCH_JOB_NODE_INDEX}.txt ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:/CnC/summary-${AWS_BATCH_JOB_NODE_INDEX}.txt

log "c finished node "${AWS_BATCH_JOB_NODE_INDEX}

wait_for_termination() {
  OLD=-1
  FLAG=1
  while [ "$FLAG" == "1" ]
  do
    ls CnC/summary*.txt
    ls CnC/summary*.txt | wc | awk '{print $1}'
    SUM=`ls CnC/summary*.txt | wc | awk '{print $1}'`
    if [ "$OLD" -ne "$SUM" ]; then echo; echo "c progress: "$SUM" out of "${AWS_BATCH_JOB_NUM_NODES}; OLD=$SUM; fi
    if [ "$SUM" == "${AWS_BATCH_JOB_NUM_NODES}" ]; then echo "c DONE: ALL NODE TERMINATED"; FLAG=0; break; fi
    if [ "$FLAG" == "1" ]; then sleep 1; fi
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
