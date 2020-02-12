DIR=$1

cd $DIR/march_cu; make $1; cd ..;
cd $DIR/iglucose/core; make $1; cd ../simp; make $1; cd ../..;
#cd lingeling; ./configure.sh; make $1; cd ..;
