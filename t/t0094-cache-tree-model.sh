#!/bin/sh

test_description='model index membership across cache-tree updates'

. ./test-lib.sh

# Keep the arithmetic within signed 32-bit range, even on shells without
# wider integers. Use the high byte, rather than the less random low bits.
model_random () {
	random_state=$(((random_state * 25173 + 13849) % 65536)) &&
	random_value=$((random_state / 256))
}

model_paths () {
	echo base &&
	bit=1 &&
	for path in file0 file1 dir/file2 dir/file3 other/file4
	do
		if test $(($1 & bit)) != 0
		then
			echo "$path" || return 1
		fi &&
		bit=$((bit * 2)) || return 1
	done
}

model_check () {
	model_paths "$staged" | sort >expect &&
	git ls-files >index &&
	git ls-tree -r --name-only HEAD >tree &&
	test_cmp expect index &&
	test_cmp expect tree
}

model_sequence () {
	seed=$1 &&
	random_state=$seed &&
	staged=0 &&
	head=0 &&
	history= &&
	>base &&
	git add base &&
	git commit -qm base &&
	model_check &&
	mkdir dir other &&
	for step in $(test_seq 64)
	do
		model_random &&
		action=$((random_value % 6)) &&
		model_random &&
		pick=$((random_value % 5)) &&
		bit=$((1 << pick)) &&
		case $pick in
		0) path=file0 ;;
		1) path=file1 ;;
		2) path=dir/file2 ;;
		3) path=dir/file3 ;;
		4) path=other/file4 ;;
		esac &&
		case $action in
		0|1)
			echo "$seed/$step: stage $path" &&
			echo "$seed-$step" >"$path" &&
			git add "$path" &&
			staged=$((staged | bit))
			;;
		2)
			# Removing a path absent from HEAD exercises CE_REMOVE.
			if test $((staged & bit)) != 0 &&
			   test $((head & bit)) = 0
			then
				echo "$seed/$step: unstage $path" &&
				git restore --staged -- "$path" &&
				staged=$((staged & ~bit)) || return 1
			fi
			;;
		3|4)
			# diff-index reads index entries without trusting cache-tree.
			if git diff-index --cached --quiet HEAD
			then
				continue
			else
				test $? = 1 || return 1
			fi &&
			echo "$seed/$step: commit" &&
			git commit -qm "seed $seed step $step" &&
			history="$head $history" &&
			head=$staged &&
			model_check
			;;
		5)
			if test -n "$history"
			then
				echo "$seed/$step: reset --soft HEAD^" &&
				git reset --soft HEAD^ &&
				set -- $history &&
				head=$1 &&
				shift &&
				history="$*" || return 1
			fi
			;;
		esac || return 1
	done
}

# Each bit in staged/head represents one path. Committing saves the old
# HEAD model on a stack; a soft reset pops it without changing staged.
# In particular, do not run write-tree between transitions: that could
# repair a stale cache-tree before the commit oracle gets to observe it.
for seed in 1 2 3 4 5 6 7 8
do
	test_expect_success "index and committed tree match model (seed $seed)" '
		test_create_repo "model-$seed" &&
		(
			cd "model-$seed" &&
			model_sequence "$seed"
		)
	'
done

test_done
