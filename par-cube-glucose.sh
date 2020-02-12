#!/bin/bash

if [ -z "$1" ]
then
  CNF=/CnC/formula.cnf
  aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} $CNF
  DIR=/CnC/
else
  CNF=$1
  DIR=.
fi

# check if input file exists, otherwise terminate
if [ ! -f "$CNF" ]; then echo "c ERROR formula does not exit"; exit 1; fi

PAR=${NUM_PROCESSES}
OUT=/tmp

if [ -z "$PAR" ]; then PAR=4; fi

echo $PAR

/usr/sbin/sshd -D &

rm $OUT/output*.txt
touch $OUT/output.txt

$DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ -d 15
# $DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ $2 $3 $4 $5 $6 $7 $8 $9

OLD=-1
FLAG=1
while [ "$FLAG" == "1" ]
do
  cat $OUT/output*.txt | grep "SAT" | awk '{print $1}' | sort | uniq -c | tr "\n" "\t";
   
  SAT=`cat $OUT/output*.txt | grep "^SAT" | awk '{print $1}' | uniq`
  if [ "$SAT" == "SAT" ]; then echo "ONE JOB SAT"; pkill -TERM -P $$; FLAG=0; fi

  UNSAT=`cat $OUT/output*.txt | grep "^UNSAT" | wc |awk '{print $1}'`
  if [ "$OLD" -ne "$UNSAT" ]; then echo $UNSAT $PAR; OLD=$UNSAT; fi
  if [ "$UNSAT" == "$PAR" ]; then echo "c ALL JOBS UNSAT"; pkill -TERM -P $$; FLAG=0; break; fi
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
