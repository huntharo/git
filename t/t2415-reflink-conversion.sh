#!/bin/sh

test_description='reflink checkout compares ordinary output'
. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

# The source and recipient have independent index/stat and conversion contexts.
# No test changes index timestamps or invents stat data.
setup_source () {
	src=$1 rule=$2 &&
	git init -q "$src" &&
	if test "$rule" = autocrlf
	then
		git -C "$src" config core.autocrlf true
	else
		printf "* %s\n.gitattributes -text\n" "$rule" >"$src/.gitattributes"
	fi &&
	make_blob_file "$src/file" 64 &&
	git -C "$src" add . &&
	git -C "$src" update-index --chmod=+x file &&
	git -C "$src" commit -qm base &&
	rm "$src/file" &&
	git -C "$src" checkout-index -afu &&
	reflink_stable_source "$src"
}

# Compare fresh creation, rather than reset of an existing representation.
checkout_pair () {
	src=$1 &&
	git -C "$src" -c checkout.workers=$workers \
		-c checkout.thresholdForParallelism=0 worktree add -q --detach \
		--no-reflink ../expect &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
	git -C "$src" -c checkout.workers=$workers \
		-c checkout.thresholdForParallelism=0 worktree add -q --detach \
		--reflink ../actual &&
	describe_tree expect >expect.tree &&
	describe_tree actual >actual.tree &&
	test_cmp expect.tree actual.tree &&
	git -C expect ls-files -s >expect.index &&
	git -C actual ls-files -s >actual.index &&
	test_cmp expect.index actual.index &&
	git -C actual status --porcelain >status &&
	test_must_be_empty status
}

remove_pair () {
	git -C "$1" worktree remove -f ../expect &&
	git -C "$1" worktree remove -f ../actual &&
	rm -f trace.json
}

test_expect_success 'setup explicit CRLF, autocrlf and auto-detected sources' '
	setup_source explicit "text eol=crlf" &&
	setup_source autocrlf autocrlf &&
	setup_source auto "text=auto eol=crlf" &&
	# Force a mixed-ending blob into the index, as a historical blob can
	# predate normalization. Auto checkout must preserve it as a whole.
	make_blob_file auto/mixed 64 &&
	perl -pi -e "s/\n/\r\n/ if 1 .. 10" auto/mixed &&
	make_blob_file auto/binary 64 &&
	printf "\\000" >>auto/binary &&
	perl -e "print q(x) x 65536" >auto/no-lf &&
	git -C auto add binary no-lf &&
	oid=$(git -C auto hash-object -w --no-filters mixed) &&
	git -C auto update-index --add --cacheinfo 100644,$oid,mixed &&
	git -C auto commit -qm detection &&
	reflink_stable_source auto
'

for workers in 1 8
do
	for src in explicit autocrlf auto
	do
		test_expect_success "matched $src output equals ordinary checkout ($workers workers)" '
			test_when_finished "remove_pair $src" &&
			checkout_pair "$src" &&
			test_has_crlf actual/file &&
			test_cmp "$src/file" actual/file
		'

		test_expect_success REFLINK "matched $src output shares blocks ($workers workers)" '
			test_when_finished "remove_pair $src" &&
			checkout_pair "$src" &&
			test_shared "$src/file" actual/file &&
			if test "$src" = auto
			then
				for f in mixed binary no-lf
				do
					test_cmp "$src/$f" "actual/$f" &&
					test_shared "$src/$f" "actual/$f" || return 1
				done &&
				test_reflink_count output-compared 5 trace.json
			elif test "$src" = autocrlf
			then
				test_reflink_count output-compared 1 trace.json
			else
				test_reflink_count output-compared 2 trace.json
			fi
		'
	done

done

test_expect_success 'changing attributes leaves a clean LF donor with current CRLF rules' '
	setup_source changed "text eol=lf" &&
	cp changed/file original-lf &&
	echo "file text eol=crlf" >changed/.gitattributes &&
	git -C changed add .gitattributes &&
	git -C changed commit -qm attributes-only &&
	# Age naturally, then use an ordinary refresh, preserving the donor
	# inode/mtime/ctime/size throughout the refresh.
	ls -in changed/file >before &&
	sleep 1 &&
	git -C changed update-index --refresh &&
	ls -in changed/file >after &&
	test_cmp before after &&
	test_cmp original-lf changed/file &&
	git -C changed status --porcelain >status &&
	test_must_be_empty status
'

for workers in 1 8
do
	test_expect_success "clean LF donor under CRLF rules falls back ($workers workers)" '
		test_when_finished "remove_pair changed" &&
		checkout_pair changed &&
		test_has_crlf actual/file &&
		! cmp -s changed/file actual/file &&
		test_not_shared changed/file actual/file
	'

	test_expect_success REFLINK "LF mismatch is compared and discarded ($workers workers)" '
		test_when_finished "remove_pair changed" &&
		checkout_pair changed &&
		test_reflink_count output-compared 2 trace.json &&
		test_reflink_count verify-failed 1 trace.json
	'

done

test_expect_success 'reverse attribute change leaves a clean CRLF donor' '
	setup_source reverse "text eol=crlf" &&
	echo "file text eol=lf" >reverse/.gitattributes &&
	git -C reverse add .gitattributes &&
	git -C reverse commit -qm attributes-only &&
	reflink_stable_source reverse &&
	test_has_crlf reverse/file &&
	git -C reverse status --porcelain >status &&
	test_must_be_empty status
'

for workers in 1 8
do
	test_expect_success "clean CRLF donor under LF rules falls back ($workers workers)" '
		test_when_finished "remove_pair reverse" &&
		checkout_pair reverse &&
		! cmp -s reverse/file actual/file &&
		test_not_shared reverse/file actual/file
	'
done

test_expect_success 'source and recipient use distinct worktree conversion config' '
	setup_source config "text" &&
	git -C config config extensions.worktreeConfig true &&
	git -C config config core.autocrlf false &&
	git -C config config core.eol crlf &&
	git -C config config --worktree core.eol lf &&
	# The first checkout used native platform line endings. Recreate
	# the donor after selecting LF instead of only refreshing its stat data.
	rm config/file &&
	git -C config checkout-index -fu file &&
	! test_has_crlf config/file &&
	reflink_stable_source config
'

for workers in 1 8
do
	test_expect_success "source LF config cannot authorize recipient CRLF bytes ($workers workers)" '
		test_when_finished "remove_pair config" &&
		for wt in expect actual
		do
			git -C config worktree add -q --detach --no-checkout \
				--no-reflink ../$wt &&
			git -C $wt config --worktree core.eol crlf || return 1
		done &&
		git -C actual config --worktree checkout.reflink true &&
		git -C expect -c checkout.workers=$workers \
			-c checkout.thresholdForParallelism=0 reset -q --hard &&
		git -C actual -c checkout.workers=$workers \
			-c checkout.thresholdForParallelism=0 reset -q --hard &&
		describe_tree expect >expect.tree &&
		describe_tree actual >actual.tree &&
		test_cmp expect.tree actual.tree &&
		test_has_crlf actual/file &&
		! cmp -s config/file actual/file &&
		test_not_shared config/file actual/file
	'
done

for workers in 1 8
do
	for mode in dirty stale racy tamper replace
	do
		test_expect_success "unsafe converted $mode donor falls back ($workers workers)" '
			test_when_finished "remove_pair unsafe; rm -rf unsafe" &&
			setup_source unsafe "text eol=crlf" &&
			case "$mode" in
			dirty)
				# Restore mtime after a same-size edit: ctime still tells.
				cp -p unsafe/file saved &&
				printf Z | dd of=unsafe/file bs=1 count=1 conv=notrunc &&
				touch -r saved unsafe/file
				;;
			stale)
				echo stale >>unsafe/file
				;;
			racy)
				test-tool chmtime =+10 unsafe/file &&
				git -C unsafe update-index --refresh
				;;
			tamper)
				GIT_TEST_REFLINK_TAMPER=file &&
				export GIT_TEST_REFLINK_TAMPER
				;;
			replace)
				GIT_TEST_REFLINK_TAMPER=file:replace &&
				export GIT_TEST_REFLINK_TAMPER
				;;
			esac &&
			test_when_finished "sane_unset GIT_TEST_REFLINK_TAMPER" &&
			checkout_pair unsafe &&
			if test "$mode" != replace
			then
				test_not_shared unsafe/file actual/file
			fi
		'
	done

done


# Materialize conversions with real checkout/index timestamps. The last path's
# smudge delays the index write, so file and control are genuinely non-racy.
# core.attributesFile is source-only and never committed into the recipient.
test_expect_success 'setup same-size ident and historical filter donors' '
	: >empty-attributes &&
	for kind in ident filter
	do
		src=history-$kind &&
		git init -q "$src" &&
		git -C "$src" config checkout.reflink false &&
		git -C "$src" config extensions.worktreeConfig true &&
		make_blob_file "$src/control" 64 &&
		make_blob_file "$src/file" 64 &&
		printf "\044Id: %s \044\n" "$(test_oid zero)" >>"$src/file" &&
		echo delay >"$src/zzz" &&
		git -C "$src" add . &&
		git -C "$src" commit -qm raw &&
		git -C "$src" config --worktree core.attributesFile \
			"$TRASH_DIRECTORY/$src.attributes" &&
		git -C "$src" config --worktree filter.delay.smudge "sleep 2; cat" &&
		echo "zzz filter=delay" >"$src.attributes" &&
		if test "$kind" = ident
		then
			echo "file ident" >>"$src.attributes"
		else
			git -C "$src" config --worktree filter.rot13.clean \
				"tr A-Za-z N-ZA-Mn-za-m" &&
			git -C "$src" config --worktree filter.rot13.smudge \
				"tr A-Za-z N-ZA-Mn-za-m" &&
			echo "file filter=rot13" >>"$src.attributes"
		fi &&
		rm "$src/control" "$src/file" "$src/zzz" &&
		git -C "$src" checkout-index -fu --all &&
		git -C "$src" show HEAD:file >raw &&
		test "$(wc -c <raw)" -eq "$(wc -c <"$src/file")" &&
		! cmp -s raw "$src/file" || return 1
	done &&
	# Remove only the historical filter rule, leaving the donor/index alone.
	echo "zzz filter=delay" >history-filter.attributes &&
	git -C history-filter check-attr filter -- file >attr &&
	echo "file: filter: unspecified" >expect.attr &&
	test_cmp expect.attr attr
'

for workers in 1 8
do
	for kind in ident filter
	do
		test_expect_success REFLINK "same-size $kind donor equals ordinary output ($workers workers)" '
			src=history-$kind &&
			test_when_finished "remove_pair $src" &&
			for wt in expect actual
			do
				git -C "$src" worktree add -q --detach --no-checkout \
					--no-reflink ../$wt &&
				git -C $wt config --worktree core.attributesFile \
					"$TRASH_DIRECTORY/empty-attributes" || return 1
			done &&
			git -C expect -c checkout.reflink=false reset -q --hard &&
			GIT_TRACE2_EVENT="$TRACE_JSON" GIT_INTERNAL_WORKTREE_ADD_CHECKOUT=1 \
			git -C actual -c checkout.reflink=true -c checkout.workers=$workers \
				-c checkout.thresholdForParallelism=0 reset -q --hard &&
			test_cmp expect/file actual/file &&
			describe_tree expect >expect.tree &&
			describe_tree actual >actual.tree &&
			test_cmp expect.tree actual.tree &&
			git -C actual diff-files --quiet &&
			test_not_shared "$src/file" actual/file &&
			test_shared "$src/control" actual/control &&
			test_reflink_count verify-failed 1 trace.json &&
			test_reflink_count output-compared 2 trace.json &&
			test_reflink_count cloned 1 trace.json
		'
	done
done

test_done
