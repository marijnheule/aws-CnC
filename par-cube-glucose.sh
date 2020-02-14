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

  touch $HOST_FILE_PATH
  IP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  MAXCORES=$(nproc)
  log "c master details -> $IP:$MAXCORES"
  echo "$IP slots=$MAXCORES" >> $HOST_FILE_PATH
  LINES=$(ls -dq /tmp/hostfile* | wc -l)
  while [ "${AWS_BATCH_JOB_NUM_NODES}" -gt "${LINES}" ]
  do
    cat $HOST_FILE_PATH
    LINES=$(ls -dq /tmp/hostfile* | wc -l)

    log "c $LINES out of $AWS_BATCH_JOB_NUM_NODES nodes joined, check again in 1 second"
    sleep 1
  done

  python /CnC/make_combined_hostfile.py ${IP}
  $DIR/march_cu/march_cu $CNF -o $OUT/cubes-$$.txt -d 10

  for (( NODE=0; NODE<${AWS_BATCH_JOB_NUM_NODES}; NODE++ ))
  do
    awk 'NR % '${AWS_BATCH_JOB_NUM_NODES}' == '$NODE'' $OUT/cubes-$$.txt > $OUT/cubes-split-$NODE.txt
    $OUT/cubes-split-$NODE.txt
    LINE_NUM=$(($NODE + 1))
    NODE_IP=$(cat combined_hostfile | head -n $LINE_NUM | tail -n 1)
    echo $NODE_IP
    scp $OUT/cubes-split-$NODE.txt $NODE_IP:/CnC/cubes-split-$NODE.txt
  done
}

report_to_master () {
  IP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  MAXCORES=$(nproc)

  log "c I am a child node -> $IP:$MAXCORES, reporting to the master node -> ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}"

  echo "$IP slots=$MAXCORES" >> $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  ping -c 3 ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}
  until scp $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX} ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:$HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  do
    echo "Sleeping 5 seconds and trying again"
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

ls /CnC/cubes-split-*
while [ ! -f /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt ]
do
  echo "c waiting for cube file to appear, sleep 1 second"
  sleep 1
done
echo "Okay lets run!"

chmod 644 /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt
cat /CnC/cubes-split-${AWS_BATCH_JOB_NODE_INDEX}.txt

#exit 2

rm -f $OUT/output*.txt
touch $OUT/output.txt

$DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ -d 15
# $DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ $2 $3 $4 $5 $6 $7 $8 $9

OLD=-1
FLAG=1
while [ "$FLAG" == "1" ]
do
#  cat $OUT/output*.txt | grep "SAT" | awk '{print $1}' | sort | uniq -c | tr "\n" "\t";
   
  SAT=`cat $OUT/output*.txt | grep "^SAT" | awk '{print $1}' | uniq`
  if [ "$SAT" == "SAT" ]; then echo "c DONE: ONE JOB SAT"; pkill -TERM -P $$; FLAG=0; fi

  UNSAT=`cat $OUT/output*.txt | grep "^UNSAT" | wc |awk '{print $1}'`
  if [ "$OLD" -ne "$UNSAT" ]; then echo; echo "c progress: "$UNSAT" UNSAT out of "$PAR; OLD=$UNSAT; fi
  if [ "$UNSAT" == "$PAR" ]; then echo "c DONE: ALL JOBS UNSAT"; pkill -TERM -P $$; FLAG=0; break; fi
  ALIVE=`ps $$ | wc | awk '{print $1}'`
  if [ "$ALIVE" == "1" ]; then echo "c PARENT TERMINATED"; pkill -TERM -P $$; FLAG=0; break; fi 
  if [ "$FLAG"  == "1" ]; then sleep 1; fi
done &

for (( CORE=0; CORE<$PAR; CORE++ ))
do
  echo "p inccnf" > $OUT/formula$$-$CORE.icnf
  cat $CNF | grep -v c >> $OUT/formula$$-$CORE.icnf
  awk 'NR % '$PAR' == '$CORE'' $OUT/cubes$$ >> $OUT/formula$$-$CORE.icnf
  $DIR/iglucose/core/iglucose $OUT/formula$$-$CORE.icnf $OUT/output-$CORE.txt -verb=0 &
done
wait

rm $OUT/cubes$$
for (( CORE=0; CORE<$PAR; CORE++ ))
do
  rm $OUT/formula$$-$CORE.icnf
done
