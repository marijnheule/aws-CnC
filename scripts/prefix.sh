OLDC=$1
LINE=$2
NEWC=$3

IFS=$'\n'
PREFIX=`head -n $LINE $OLDC | sed 's| 0||'`
for CUBE in `cat $NEWC | sed 's|a||'`
do
  echo -n $PREFIX
  echo $CUBE
done
