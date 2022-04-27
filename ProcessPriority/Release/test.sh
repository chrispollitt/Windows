#!/bin/bash
unset a
unset b
[[ -n $1 ]] && a=$1
[[ -n $2 ]] && b=$2
set -- $(tasklist /FI "IMAGENAME eq bash.exe" /NH)
tmp=/tmp/ProcessPriority.err
pid=${a-$3}
pri=${b-2}
echo ==pid==
echo pid=$pid
echo ==C++==
rm -f $tmp
touch $tmp
./GetSetProcPri.exe $pid $pri
cat $tmp
echo ==C#==
rm -f $tmp
touch $tmp
./GetSetPriCS.exe $pid $pri
cat $tmp
echo ========
