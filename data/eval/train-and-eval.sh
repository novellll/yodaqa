#!/bin/bash
#
# Usage: data/eval/train-and-eval.sh [-s N] [-m MAXHEAPSIZE] [-d DATASET] [-DPROPERY] [COMMIT [BASECOMMIT]]
#
# Perform full model training and performance evaluation of the given
# commit (may be also a branch name, or nothing to eval the HEAD).
#
# The training and test set is processed in parallel, however the
# final answer evaluation is delayed until the model is retrained.
# Sequential execution on training and test set may be specified instead
# by the -s parameter, which takes an extra number N to be set as the
# value of YODAQA_N_THREADS (typically your total #of CPUs).
# (For more than 4 CPU cores, you may want to pass -m 6000M or some
# such - it's more memory hungry over many questions than we expect
# in the default configuration.)
#
# This produces answer TSV files for training and test set
# (final, and pre-training ones with 'u' prefix before commit),
# xmi answer feature vectors file, a model parameter file and a log
# for both the train and test runs.
#
# If the evaluation has been successful, you should commit an updated
# model; that's one of the last lines printed by the list.
#
# The optional argument BASECOMMIT supports skipping phase 0 (the bulk
# of the brmson work), instead reusing data generated by BASECOMMIT
# as input for further phases.  You can use this to quickly experiment
# with late-stage pipeline parameters like size of the pruned set,
# machine learning parameters or evidence gathering improvements.
#
# Since this all involves multiple executions and we often want to
# evaluate multiple versions at once, we create a temporary clone of
# the current repo and run things there.  N.B. uncommitted changes
# are *not* tested!  The actual execution happens in the script
# `data/eval/_multistage_traineval.sh`.
#
# -d DATASET allows "train and eval" on a different dataset than
# "curated".  E.g. -d large2180 will test on the 2180-question
# noisier dataset.

set -e

if [ "$1" = "-s" ]; then
	shift; run_split=""; export YODAQA_N_THREADS=$1; shift
else
	run_split="screen"  # this executes the split async
fi
if [ "$1" = "-m" ]; then
	shift; maxheapsize=$1; shift
else
	maxheapsize=""
fi
if [ "$1" = "-d" ]; then
	shift; dataset=$1; shift
else
	dataset=curated
fi
if [ "${1:0:2}" = "-D" ]; then
	shift; system_property=$1
fi

cid=$(git rev-parse --short "${1:-HEAD}")
baserepo=$(pwd)

basecid="$2"

clonedir="../yodaqa-te-$cid"
if [ -e "$clonedir" ]; then
	ls -ld "$clonedir"
	echo "$clonedir: Directory where we would like to clone exists, try again after" >&2
	echo "rm -rf \"$clonedir\"" >&2
	exit 1
fi

git clone "$baserepo" "$clonedir"
pushd "$clonedir"
git checkout "$cid"
mkdir -p conf
cp "$baserepo"/conf/bingapi.properties conf/bingapi.properties || :

if [ -n "$maxheapsize" ]; then
	sed -i -e 's/maxHeapSize.*/maxHeapSize = "'$maxheapsize'"/' build.gradle
fi

echo "Checked out in $clonedir"
sleep 2

# Pre-build so we don't do that twice
time ./gradlew check

echo "Starting evaluation in $clonedir"
sleep 2

if [ x$run_split = x ]; then
	wait_on_barriers=0
else
	wait_on_barriers=1
fi

screen -m sh -c "
	$run_split \"$baserepo\"/data/eval/_multistage_traineval.sh \"$baserepo\" \"${dataset}-train\" 1 0 $basecid $system_property;
	if [ $wait_on_barriers = 0 ]; then rm _multistage-barrier*; else sleep 10; fi
	$run_split \"$baserepo\"/data/eval/_multistage_traineval.sh \"$baserepo\" \"${dataset}-test\" 0 $wait_on_barriers $basecid $system_property
"

popd

data/eval/tsvout-stats.sh "$cid"
echo
echo "Now, you may want to do and commit:"
for i in "" 1 2; do
	echo "cp data/ml/models/logistic${i}-${cid}.model src/main/resources/cz/brmlab/yodaqa/analysis/ansscore/AnswerScoreLogistic${i}.model"
done
echo
echo "Run finished. Press Enter to rm -rf \"$clonedir\"; Ctrl-C to preserve it for whatever reason (data and logs are not kept there)."
read x
rm -rf "$clonedir"
