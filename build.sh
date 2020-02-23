DIR=$1
FLAG=$2

cd $DIR/march_cu; make $FLAG; cd ..;
cd $DIR/iglucose/core; make $FLAG; cd ../simp; make $FLAG; cd ../..;
cd $DIR/cadical; ./configure; make $FLAG; cd ../..;
#cd lingeling; ./configure.sh; make $FLAG; cd ..;
