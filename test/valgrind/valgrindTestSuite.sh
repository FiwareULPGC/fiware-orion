#!/bin/bash
# Copyright 2013 Telefonica Investigacion y Desarrollo, S.A.U
#
# This file is part of Orion Context Broker.
#
# Orion Context Broker is free software: you can redistribute it and/or
# modify it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# Orion Context Broker is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
# General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Orion Context Broker. If not, see http://www.gnu.org/licenses/.
#
# For those usages not covered by this license please contact with
# iot_support at tid dot es

# This suite does two kinds of tests:
#
# 1. "Pure" valgrind tests, which live in this directory with the .vtest extension
# 2. Test harness (that has their own independent evolution), running in a
#    "valgrind-ized mode"
#
# A selector parameter allows to run either group 1, group 2 or both (default is both)
#



# -----------------------------------------------------------------------------
#
# FUNC_TEST_RUNNING_UNDER_VALGRIND - 
#
# This env var is set to "true" so that the harness tests will know whether they are
# running under the valgrund test suite.
# Running under valgrind, everything goes a lotr slower and sleps have to be inserted.
# We don't want these sleeps for regular harness tests, so this variable is used to
# distinguish between the two cases.
#
export FUNC_TEST_RUNNING_UNDER_VALGRIND="true"



# -----------------------------------------------------------------------------
#
# CB_TEST_PORT is used by cbTest.sh as default port
#
export CB_TEST_PORT=9999



# -----------------------------------------------------------------------------
#
# usage
#
function usage()
{
  echo $0 "[-u (usage)] [-v (verbose)] [-filter (test filter)] [-dryrun (don't execute any tests)] [-leakTest (test a memory leak)] <pure|harness>"
  exit $1
}



# -----------------------------------------------------------------------------
#
# vMsg
#
function vMsg()
{
  if [ "$verbose" = "on" ]
  then
    echo $*
  fi
}



# -----------------------------------------------------------------------------
#
# fileCleanup
#
function fileCleanup()
{
  vtest=$1

  rm -f $vtest.contextBroker.log
  rm -f $vtest.valgrindTestSuite.stderr
  rm -f $vtest.valgrindTestSuite.stdout
  rm -f $vtest.configManager.log
  rm -f $vtest.accumulator_$LISTENER_PORT
  rm -f $vtest.accumulator_$LISTENER2_PORT
}



# -----------------------------------------------------------------------------
#
# If any mongo database ftest-ftest exists, strange memory leaks appear ...
# So, before starting, it's important to remove all ftest DBs
#
function dbReset()
{
  where=$1

  if [ "$where" == "top" ]
  then
    resetScript=scripts/dbResetAllFtest.sh
  else
    resetScript=../../scripts/dbResetAllFtest.sh
  fi

  if [ -x $resetScript ]
    then
    $resetScript
  else
    pwd > /tmp/kz
    echo "Can't find $resetScript ..."
    exit 1
  fi
}

dbReset top


# -----------------------------------------------------------------------------
#
# Init file already sourced?
#
if [ "$CONTEXTBROKER_TESTENV_SOURCED" != "YES" ]
then
  if [ -f scripts/testEnv.sh ]
  then
    vMsg Sourcing scripts/testEnv.sh
    source scripts/testEnv.sh
  else
    echo "--------------------------------------------------------------------------"
    echo "Please source scripts/testEnv.sh before running the functional test suite."
    echo "--------------------------------------------------------------------------"
    exit 1
  fi
fi



# -----------------------------------------------------------------------------
#
# Parsing parameters
#
verbose=off
mode=all
TEST_FILTER=${TEST_FILTER:-"*.*test"}
dryrun=off
leakTest=off

vMsg "parsing options"
while [ "$#" != 0 ]
do
  if   [ "$1" == "-u" ];        then usage 0;
  elif [ "$1" == "-v" ];        then verbose=on;
  elif [ "$1" == "-leakTest" ]; then leakTest=on;
  elif [ "$1" == "-filter" ];   then TEST_FILTER=$2; shift;
  elif [ "$1" == "-dryrun" ];   then dryrun=on;
  elif [ "$1" == "pure" ];      then mode=pure;
  elif [ "$1" == "harness" ];   then mode=harness;
  else
    echo $0: bad parameter/option: "'"${1}"'";
    usage 1
  fi
  shift
done

if [ "$dryrun" == "on" ]
then
  okString="DryRun"
else
  okString="OK"
fi

vMsg
vMsg "----- Command line options -----"
vMsg "mode: $mode"
vMsg "filter: $TEST_FILTER"
vMsg "dryrun: $dryrun"
vMsg "leakTest: $leakTest"
vMsg




# -----------------------------------------------------------------------------
#
# SRC_TOP - getting the TOP directory
#
dir=$(dirname $0)
SRC_TOP1=${PWD}/${dir}/../..   # if called with a relative path
SRC_TOP2=${dir}/../..          # if called via $PATH or with an absolute path
if [ -d ${SRC_TOP1} ]
then
  SRC_TOP=${SRC_TOP1}
else
  SRC_TOP=${SRC_TOP2}
fi

cd $SRC_TOP
SRC_TOP=$(pwd)
cd - > /dev/null
vMsg Git repo home: $SRC_TOP
cd test/valgrind
vMsg In directory $(pwd)


# -----------------------------------------------------------------------------
#
# add - 
#
# We need this function because the regular '+' can not process correctly
# numbers with ',', as the ones generated in the valgrind report (e.g. "1,223")
#
function add()
{
  typeset -i num
  typeset -i sum
  sum=0

  for i in $*
  do
    num=$(echo $i | sed 's/,//g')
    sum=$sum+$num
  done

  echo $sum
}



# -----------------------------------------------------------------------------
#
# Start broker
#
function brokerStart()
{
    # Starting contextBroker in valgrind with a clean database
    dbReset middle
    killall contextBroker 2> /dev/null
    echo 'db.dropDatabase()' | mongo valgrindtest --quiet > /dev/null
    valgrind --memcheck:leak-check=full --show-reachable=yes --trace-children=yes contextBroker -port ${CB_TEST_PORT} -db leaktest -harakiri -t0-255 > ${NAME}.out 2>&1 &
    valgrindPid=$!

    # Awaiting valgrind to start contextBroker (sleep 10)
    typeset -i loopNo
    typeset -i loops
    loopNo=0
    loops=10

    vMsg
    while [ $loopNo -lt $loops ]
    do
      nc -z localhost ${CB_TEST_PORT} > /dev/null
      if [ "$?" == "0" ]
      then
        vMsg The orion context broker has started, listening on port $CB_TEST_PORT
        sleep 1
        break;
      fi
      vMsg Awaiting valgrind to fully start the orion context broker '('$loopNo')' ...
      sleep 1
      loopNo=$loopNo+1
    done

    # Check CB started fine
    curl -s localhost:${CB_TEST_PORT}/version | grep version > /dev/null
    result=$?
}

# -----------------------------------------------------------------------------
#
# Stop broker
#
function brokerStop()
{
  # Sending REST exit to contextBroker
  vMsg Sending REST exit to contextBroker on port $CB_TEST_PORT
  curl -s localhost:${CB_TEST_PORT}/exit/harakiri >> ${NAME}.stop.out

  vMsg Waiting for valgrind to terminate - PID: $valgrindPid
  wait $valgrindPid
}



# -----------------------------------------------------------------------------
#
# Process valgrind result
#
# It uses as argument the .out file to process
#
function processResult()
{
    filename=$1
    # Get info from valgrind
    startLine1=$(grep --text -n "LEAK SUMMARY" $filename | awk -F: '{ print $1 }' | head -1)
    startLine2=$(grep --text -n "LEAK SUMMARY" $filename | awk -F: '{ print $1 }' | tail -1)

    if [ "$startLine1" == "" ] || [ "$startLine2" == "" ]
    then
        return
    fi

    typeset -i headEndLine1
    headEndLine1=$startLine1+7

    head -$headEndLine1 $filename | tail -8 > valgrind.leakSummary

    definitelyLost1=$(grep 'definitely lost' valgrind.leakSummary | awk '{ print $4 }')
    indirectlyLost1=$(grep 'indirectly lost' valgrind.leakSummary | awk '{ print $4 }')
    possiblyLost1=$(grep 'possibly lost' valgrind.leakSummary | awk '{ print $4 }')
    stillReachable1=$(grep 'still reachable' valgrind.leakSummary | awk '{ print $4 }')

    headEndLine2=$startLine2+7

    head -$headEndLine2 $1 | tail -8 > valgrind.leakSummary2

    definitelyLost2=$(grep 'definitely lost' valgrind.leakSummary2 | awk '{ print $4 }')
    indirectlyLost2=$(grep 'indirectly lost' valgrind.leakSummary2 | awk '{ print $4 }')
    possiblyLost2=$(grep 'possibly lost' valgrind.leakSummary2 | awk '{ print $4 }')
    stillReachable2=$(grep 'still reachable' valgrind.leakSummary2 | awk '{ print $4 }')

    \rm valgrind.leakSummary valgrind.leakSummary2

    lost=$(add $definitelyLost1 $indirectlyLost1 $definitelyLost2 $indirectlyLost2)
}



# -----------------------------------------------------------------------------
#
# Printing related functions
#
function printTestLinePrefix()
{
  if [ "$dryrun" == "off" ]
  then
    name="Test "
  else
    name=""
  fi

  if [ $testNo -lt 10 ]
  then
    testNoString=${name}"00"${testNo}"/"${noOfTests}": "
  elif [ $testNo -lt 100 ]
  then
    testNoString=${name}"0"${testNo}"/"${noOfTests}": "
  else
    testNoString=${name}${testNo}"/"${noOfTests}": "
  fi
}

function printNotImplementedString()
{
  echo "NOT IMPLEMENTED - skipped"
  echo                                    >> /tmp/valgrindTestSuiteLog
  echo "$1 not implemented - skipped"     >> /tmp/valgrindTestSuiteLog
  echo                                    >> /tmp/valgrindTestSuiteLog
}

function printImplementedString()
{
  echo '# ---------------------------------------------' >> /tmp/valgrindTestSuiteLog
  echo '# '                                              >> /tmp/valgrindTestSuiteLog
  echo "# $1"                                            >> /tmp/valgrindTestSuiteLog
  echo '# '                                              >> /tmp/valgrindTestSuiteLog
}



# -----------------------------------------------------------------------------
#
# setNumberOfTests
#
function setNumberOfTests()
{
  noOfTests=0

  if [ "$runPure" -eq "1" ]
  then
    for vtest in $(ls $TEST_FILTER 2> /dev/null)
    do
      noOfTests=$noOfTests+1
    done
  fi

  if [ "$runHarness" -eq "1" ]
  then
    for file in $(find ../functionalTest/cases -name "$TEST_FILTER")
    do
      noOfTests=$noOfTests+1
    done
  fi

  if [ "$leakTest" == "on" ]
  then
    noOfTests=$noOfTests+1
  fi

  vMsg "Number Of Tests: " $noOfTests
}



# -----------------------------------------------------------------------------
#
# Failed tests
#
function failedTest()
{
  _file=$2
  _lost=$3
  _dir=$4

  if [ "$_lost" != "0" ]
  then
    echo "FAILED (lost: $_lost). Check $_file.valgrind.out for clues"
  fi

  testFailures=$testFailures+1

  if [ "$_dir" != "" ]
  then
    failedTests[$testFailures]=$_dir/$_file".test (lost $_lost bytes)"
  else
    failedTests[$testFailures]=$_file".test (lost $_lost bytes)"
  fi

  failedTests[$testFailures+1]=$okString
}


# -----------------------------------------------------------------------------
#
# Main program
#

# Port tests
nc -z localhost ${CB_TEST_PORT} > /dev/null 
if [ "$?" == "0" ]
then
   # Successful nc means that port CB_TEST_PORT is used, thus exit
   echo "Port $CB_TEST_PORT is in use. Aborting"
   exit 1
fi


vMsg "Running valgrind test suite"
if [ "$leakTest" == "on" ]
then
  runPure=0
  runHarness=0
  vMsg "Selecting only the leak test"
elif [ "$mode" == "pure" ]
then
  runPure=1
  runHarness=0
  vMsg "Selecting only pure valgrind tests"
elif [ "$mode" == "harness" ]
then
  runPure=0
  runHarness=1
  vMsg "Selecting only harness tests"
else
  runPure=1
  runHarness=1
  vMsg "Selecting both pure valgrind and harness tests"
fi

date > /tmp/valgrindTestSuiteLog

typeset -i noOfTests
noOfTests=0
setNumberOfTests

declare -A failedTests
declare -A harnessErrorV
typeset -i harnessErrors
typeset -i testNo
typeset -i testFailures
testNo=0;
testFailures=0
harnessErrors=0


if [ "$runPure" -eq "1" ] || [ "$leakTest" == "on" ]
then
  leakTestFile=""
  if [ "$leakTest" == "on" ]
  then
    fileList="leakTest.xtest"
  else
    fileList=$(ls $TEST_FILTER 2> /dev/null)
  fi

  for vtest in $fileList
  do
    testNo=$testNo+1
    printTestLinePrefix

    init="$testNoString $vtest ..........................................................................................................................................................."
    init=${init:0:150}
    echo -n $init" "

    typeset -i lines
    lines=$(wc -l $vtest | awk '{ print $1 }')
    if [ $lines -lt 23 ]
    then
       printNotImplementedString $vtest
       continue
    fi
    printImplementedString $vtest

    # Executing $vtest
    NAME="./$vtest"
    typeset -i lost
    lost=0

    if [ "$dryrun" == "off" ]
    then
      fileCleanup $vtest
      brokerStart
      if [ "$result" != "0" ]
      then
        echo "context broker didn't start! check $NAME.out"
        continue
      fi

      vMsg Executing $vtest
      command ./$vtest > /tmp/valgrindTestLog.stdout 2> /tmp/valgrindTestLog.stderr    
      cat /tmp/valgrindTestLog.stdout >> /tmp/valgrindTestSuiteLog
      vTestResult=$?
      vMsg vTestResult=$vTestResult

      brokerStop

      if [ "$vTestResult" != 0 ]
      then
        echo "(HARNESS FAILURE) Test ended with error code $vTestResult"
        mv /tmp/contextBroker.log                $vtest.contextBroker.log
        mv /tmp/valgrindTestLog.stderr           $vtest.valgrindTestSuite.stderr
        mv /tmp/valgrindTestLog.stdout           $vtest.valgrindTestSuite.stdout
        mv /tmp/configManager/contextBroker.log  $vtest.configManager.log
        mv /tmp/accumulator_$LISTENER_PORT       $vtest.accumulator_$LISTENER_PORT
        mv /tmp/accumulator_$LISTENER2_PORT      $vtest.accumulator_$LISTENER2_PORT

        failedTest "$vtest.valgrind.out" $vtest 0 "valgrind"
      else
        fileCleanup $vtest

        typeset -i headEndLine1
        typeset -i headEndLine2
        processResult ${NAME}.out
      fi
    else
      echo "dryRun"
    fi

    if [ "$lost" != "0" ]
    then
      failedTest "test/valgrind/$vtest.*" $vtest $lost "valgrind"
    elif [ "$vTestResult" == 0 ]
    then
      echo $okString
      rm -f $vtest.out
    fi

    echo >> /tmp/valgrindTestSuiteLog
    echo >> /tmp/valgrindTestSuiteLog
  done
fi

#
# No diff tool for harnessTest when running from valgrind test suite
#
unset CB_DIFF_TOOL

if [ "$runHarness" -eq "1" ]
then
  if [ "$CONTEXTBROKER_TESTENV_SOURCED" != "YES" ]
  then
    echo "$0: please source the test script (scripts/testEnv.sh)"
    exit 1
  fi

  cd $SRC_TOP/test/functionalTest/cases
  vMsg TEST_FILTER: $TEST_FILTER
  for file in $(find . -name "$TEST_FILTER" | sort)
  do
    htest=$(basename $file | awk -F '.' '{print $1}')
    directory=$(dirname $file)
    dir=$(basename $directory)
    file=$htest.test

    vMsg file: $file
    vMsg htest: $htest

    testNo=$testNo+1
    printTestLinePrefix
    init="$testNoString $dir/$htest ..........................................................................................................................................................."
    init=${init:0:150}
    echo -n $init" "

    # In the case of harness test, we check that the test is implemented checking
    # that the word VALGRIND_READY apears in the .test file (usually, in a commented line)
    grep VALGRIND_READY $SRC_TOP/test/functionalTest/cases/$directory/$file > /dev/null 2>&1
    if [ "$?" -ne "0" ]
    then
      printNotImplementedString $htest
      continue
    fi

    cd $SRC_TOP
    printImplementedString $htest
    typeset -i lost
    lost=0

    if [ "$dryrun" == "off" ]
    then
      detailForOkString=''
      vMsg "------------------------------------------------"
      vMsg running harnessTest.sh with $file in $(pwd)
      vMsg "------------------------------------------------"
      VALGRIND=1 test/functionalTest/testHarness.sh --filter $file > /tmp/testHarness 2>&1
      status=$?
      if [ "$status" != "0" ]
      then
        mv /tmp/testHarness         test/functionalTest/cases/$directory/$htest.harness.out
        cp /tmp/contextBroker.log   test/functionalTest/cases/$directory/$htest.contextBroker.log
        detailForOkString=" (functional test exit code: $status)"
        harnessErrorV[$harnessErrors]="$file"
        harnessErrors=$harnessErrors+1
        # No exit here - sometimes harness tests fail under valgrind ...
      fi

      if [ ! -f /tmp/valgrind.out ]
      then
        echo " FAILURE! (no valgrind output for functional test $file)"
        exit 3
      fi

      mv /tmp/valgrind.out test/functionalTest/cases/$directory/$htest.valgrind.out
      
      typeset -i headEndLine1
      typeset -i headEndLine2
      vMsg processing $directory/$htest.valgrind.out in $(pwd)
      vMsg "calling processResult"
      processResult test/functionalTest/cases/$directory/$htest.valgrind.out
      vMsg "called processResult"
    fi
    cd - > /dev/null

    if [ "$lost" != "0" ]
    then
      failedTest "test/functionalTest/cases/$htest.valgrind.*" $htest $lost $dir
    else
      echo $okString $detailForOkString
    fi

  done
fi

if [ "${failedTests[1]}" != "" ]
then
  echo
  echo
  echo "$testFailures tests leaked memory:"
  typeset -i ix
  ix=0

  while [ $ix -ne $testFailures ]
  do
    ix=$ix+1
    echo "  " ${failedTests[$ix]}
  done

  echo "---------------------------------------"
  exit 1
fi


if [ $harnessErrors != 0 ]
then
  echo
  echo
  echo "$harnessErrors functional test failed (not a leak, just a failure):"
  typeset -i ix
  ix=0

  while [ $ix -ne $harnessErrors ]
  do
    echo "  " ${harnessErrorV[$ix]}
    ix=$ix+1
  done

  echo "---------------------------------------"
fi


if [ "$dryrun" == "off" ]
then
  echo "Great, all valgrind tests ran without any memory leakage"
fi

exit 0
