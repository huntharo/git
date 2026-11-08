#!/bin/sh

test_description='explicit worktree re-sharing'
. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

test_lazy_prereq NATIVE_DEDUPE '
	test-tool reflink dedupe-probe .
'
test_lazy_prereq RESHARE '
	case $(uname -s) in
	Darwin) test-tool reflink probe . ;;
	*) test-tool reflink dedupe-probe . ;;
	esac
'

# Read a summary field, rather than the same named per-path field.
summary_field () {
	sed -n "/^summary$/,\$ s/^$1 //p" "$2"
}

test_field () {
	echo "$2" >expect.field &&
	summary_field "$1" "$3" >actual.field &&
	test_cmp expect.field actual.field
}

private_target () {
	git -C source worktree add -q --detach --no-reflink ../target base &&
	reflink_stable_source target
}

remove_target () {
	git -C source worktree remove -f ../target &&
	git -C source config checkout.reflink false
}

metadata () {
	for f in plain crlf
	do
		test-tool reflink metadata "target/$f" >metadata.tmp || return 1
		if test "$(uname -s)" = Darwin
		then
			# Replacement preserves birth/m/atime, mode and owner; inode/ctime change.
			awk '/^birth/ {print; next} {$2="inode"; $12="ctime"; $13="ctime"; print}' metadata.tmp
		else
			cat metadata.tmp
		fi
	done
}

test_expect_success 'setup independent source' '
	git init -q source &&
	git -C source config checkout.reflink false &&
	echo "crlf text eol=crlf" >source/.gitattributes &&
	make_blob_file source/plain 64 &&
	make_blob_file source/crlf 64 &&
	git -C source add . &&
	git -C source update-index --chmod=+x plain &&
	git -C source commit -qm base &&
	git -C source tag base &&
	rm source/plain source/crlf &&
	git -C source checkout-index -afu &&
	reflink_stable_source source
'

test_expect_success 'porcelain dry-run preserves bytes and metadata on every backend' '
	test_when_finished remove_target &&
	private_target &&
	describe_tree target >before.tree &&
	metadata >before.stat &&
	git -C target worktree reflink --dry-run --porcelain >out &&
	metadata >after.stat &&
	test_cmp before.stat after.stat &&
	describe_tree target >after.tree &&
	test_cmp before.tree after.tree &&
	test_grep "^reflink 1$" out &&
	if test_have_prereq REFLINK_BUILD
	then test_field scanned 3 out
	else test_field scanned 0 out
	fi &&
	test_field reshared 0 out &&
	test_field observed-private-reduction 0 out &&
	test_not_shared source/plain target/plain &&
	test_not_shared source/crlf target/crlf
'

test_expect_success 'NUL porcelain supports a target worktree argument' '
	test_when_finished remove_target &&
	private_target &&
	git -C source worktree reflink --dry-run --porcelain -z ../target >out &&
	tr "\\000" "\\n" <out >lines &&
	test_grep "^reflink 1$" lines &&
	test_grep "^dry-run 1$" lines &&
	if test_have_prereq REFLINK_BUILD
	then test_field scanned 3 lines
	else test_field scanned 0 lines
	fi
'

for workers in 1 8
do
	test_expect_success RESHARE "private stat-clean targets share without hashing or conversion ($workers workers)" '
		test_when_finished remove_target &&
		private_target &&
		metadata >before.stat &&
		git -C target -c checkout.workers=$workers worktree reflink --porcelain >out &&
		metadata >after.stat &&
		test_cmp before.stat after.stat &&
		test_field content-checked 0 out &&
		test_field content-check-bytes 0 out &&
		if test_have_prereq NATIVE_DEDUPE
		then test_field userspace-compared 0 out
		else test "$(summary_field userspace-compared out)" -ge 2
		fi &&
		test_field failed 0 out &&
		test "$(summary_field stat-clean out)" -ge 2 &&
		if test_have_prereq NATIVE_DEDUPE
		then test "$(summary_field native-attempts out)" -ge 2
		else test "$(summary_field clone-attempts out)" -ge 2
		fi &&
		test_shared source/plain target/plain &&
		test_shared source/crlf target/crlf &&
		test_cmp source/plain target/plain &&
		test_cmp source/crlf target/crlf
	'

	test_expect_success RESHARE "second run is metadata-only and idempotent ($workers workers)" '
		test_when_finished remove_target &&
		private_target &&
		git -C target worktree reflink &&
		metadata >before.stat &&
		git -C target -c checkout.workers=$workers worktree reflink --porcelain >out &&
		metadata >after.stat &&
		test_cmp before.stat after.stat &&
		test_field content-checked 0 out &&
		test_field stat-clean 0 out &&
		test_field userspace-compared 0 out &&
		test_field native-attempts 0 out &&
		test_field reshared 0 out &&
		test "$(summary_field already-shared out)" -ge 2
	'

	test_expect_success "dirty target remains dirty with identical existing bytes ($workers workers)" '
		test_when_finished remove_target &&
		private_target &&
		echo dirty >>target/plain &&
		dd if=target/plain of=saved bs=8192 &&
		git -C target worktree reflink --porcelain >out &&
		test_cmp saved target/plain &&
		test_not_shared source/plain target/plain &&
		git -C target status --porcelain --untracked-files=no >status &&
		test_grep "M plain$" status
	'

	test_expect_success RESHARE "same-size dirty ambiguity takes normal content verification ($workers workers)" '
		test_when_finished remove_target &&
		private_target &&
		printf Z | dd of=target/plain bs=1 count=1 conv=notrunc &&
		dd if=target/plain of=saved bs=8192 &&
		git -C target -c core.useNanoSec=true worktree reflink --porcelain >out &&
		test_cmp saved target/plain &&
		test_field content-checked 1 out &&
		test_grep "^reason target-dirty$" out &&
		test_not_shared source/plain target/plain
	'

done

test_expect_success 'unsupported backend explicitly reports safe skips' '
	if test_have_prereq RESHARE
	then
		return 0
	fi &&
	test_when_finished remove_target &&
	private_target &&
	metadata >before.stat &&
	git -C target worktree reflink --porcelain >out &&
	metadata >after.stat &&
	test_cmp before.stat after.stat &&
	test_grep "^backend unsupported$" out &&
	if test_have_prereq REFLINK_BUILD
	then test_grep "^reason unsupported-safe-dedupe$" out
	else test_field scanned 0 out
	fi &&
	test_field reshared 0 out &&
	test_not_shared source/plain target/plain
'

test_expect_success RESHARE 'dry-run estimates potential without native calls or allocation changes' '
	test_when_finished remove_target &&
	private_target &&
	test-tool reflink private-bytes target >before.usage &&
	metadata >before.stat &&
	git -C target worktree reflink -n --porcelain >out &&
	metadata >after.stat &&
	test_cmp before.stat after.stat &&
	test-tool reflink private-bytes target >after.usage &&
	test_cmp before.usage after.usage &&
	test_field native-attempts 0 out &&
	test_field content-checked 0 out &&
	test "$(summary_field potential-private-reduction out)" -ge 131072 &&
	test_field observed-private-reduction 0 out
'

test_expect_success RESHARE 'partially shared files recover only their private allocation' '
	test_when_finished remove_target &&
	private_target &&
	git -C target worktree reflink &&
	dd if=source/plain of=target/plain bs=4096 count=1 conv=notrunc &&
	git -C target add plain &&
	reflink_stable_source target &&
	test-tool reflink private-bytes target/plain >before.usage &&
	read private allocated files shared <before.usage &&
	test "$private" -gt 0 && test "$private" -lt "$allocated" &&
	metadata >before.stat &&
	git -C target worktree reflink --porcelain >out &&
	metadata >after.stat &&
	test_cmp before.stat after.stat &&
	test_field observed-private-reduction "$private" out &&
	test_field content-checked 0 out &&
	test_shared source/plain target/plain
'

test_expect_success RESHARE 'hardlinks and sparse targets are preserved and skipped' '
	test_when_finished remove_target &&
	private_target &&
	ln target/plain held-link &&
	test_when_finished "rm -f held-link" &&
	git -C target update-index --skip-worktree crlf &&
	metadata >before.stat &&
	git -C target worktree reflink --porcelain >out &&
	metadata >after.stat &&
	test_cmp before.stat after.stat &&
	test_grep "^reason hardlinked-target$" out &&
	test_grep "^reason index-entry$" out &&
	test_not_shared source/plain target/plain &&
	test_not_shared source/crlf target/crlf
'

test_expect_success SYMLINKS 'symlink replacements are never followed' '
	test_when_finished remove_target &&
	private_target &&
	dd if=target/plain of=held bs=8192 &&
	rm target/plain && ln -s ../held target/plain &&
	git -C target worktree reflink --porcelain >out &&
	test_path_is_file held &&
	test_cmp source/plain held &&
	test -h target/plain &&
	if test_have_prereq REFLINK_BUILD
	then test_grep "^reason target-unavailable$" out
	else test_field scanned 0 out
	fi
'

test_expect_success RESHARE 'stat-clean filtered targets invoke no clean/smudge commands' '
	test_when_finished "git -C source reset -q --hard base; reflink_stable_source source" &&
	test_when_finished remove_target &&
	echo "plain filter=record" >>source/.gitattributes &&
	git -C source config filter.record.clean "echo clean >>../filter-log; cat" &&
	git -C source config filter.record.smudge "echo smudge >>../filter-log; cat" &&
	git -C source add .gitattributes && git -C source commit -qm filtered &&
	git -C source worktree add -q --detach --no-reflink ../target HEAD &&
	reflink_stable_source source && reflink_stable_source target &&
	>filter-log &&
	git -C target worktree reflink --porcelain >out &&
	test_must_be_empty filter-log &&
	test_field content-checked 0 out &&
	test_shared source/plain target/plain
'

for old in lf crlf
do
	if test "$old" = lf
	then new=crlf
	else new=lf
	fi
	for donor in historical fresh
	do
		test_expect_success "preserve historical $old target with $donor $new donor context" '
			test_when_finished "rm -rf context-source context-target" &&
			git init -q context-source &&
			git -C context-source config checkout.reflink false &&
			echo "file text eol=$old" >context-source/.gitattributes &&
			make_blob_file context-source/file 64 &&
			git -C context-source add . && git -C context-source commit -qm old &&
			rm context-source/file && git -C context-source checkout-index -afu &&
			reflink_stable_source context-source &&
			git -C context-source worktree add -q --detach --no-reflink ../context-target HEAD &&
			reflink_stable_source context-target &&
			dd if=context-target/file of=saved bs=8192 &&
			echo "file text eol=$new" >context-source/.gitattributes &&
			git -C context-source add .gitattributes && git -C context-source commit -qm new &&
			git -C context-target reset -q --hard refs/heads/$(git -C context-source branch --show-current) &&
			test_cmp saved context-target/file &&
			if test "$donor" = fresh
			then
				rm context-source/file && git -C context-source checkout-index -afu
			fi &&
			reflink_stable_source context-source && reflink_stable_source context-target &&
			git -C context-target worktree reflink --porcelain >out &&
			test_cmp saved context-target/file &&
			if test_have_prereq RESHARE
			then
				if test "$donor" = historical
				then test_shared context-source/file context-target/file
				else test_grep "^reason representation-differs$" out
				fi
			fi &&
			git -C context-target -c checkout.reflink=true reset -q --hard &&
			test_cmp saved context-target/file
		'
	done
done

test_expect_success RESHARE 'same-size normalized equivalents still require kernel byte equality' '
	test_when_finished "rm -rf mixed-source mixed-target" &&
	git init -q mixed-source && git -C mixed-source config checkout.reflink false &&
	echo "file text eol=crlf" >mixed-source/.gitattributes &&
	perl -e "print qq(one\r\nsecond\n) x 6000" >mixed-source/file &&
	git -C mixed-source add . && git -C mixed-source commit -qm mixed &&
	git -C mixed-source worktree add -q --detach --no-reflink ../mixed-target HEAD &&
	perl -e "print qq(one\nsecond\r\n) x 6000" >mixed-target/file &&
	git -C mixed-target add file &&
	reflink_stable_source mixed-source && reflink_stable_source mixed-target &&
	dd if=mixed-target/file of=saved bs=8192 &&
	git -C mixed-target worktree reflink --porcelain >out &&
	test_cmp saved mixed-target/file &&
	test_field content-checked 0 out &&
	if test_have_prereq NATIVE_DEDUPE
	then test_field userspace-compared 0 out
	else test "$(summary_field userspace-compared out)" -gt 0
	fi &&
	test_grep "^reason representation-differs$" out &&
	test_not_shared mixed-source/file mixed-target/file
'

for change in target-write target-replace source-write source-replace
do
	test_expect_success RESHARE "concurrent $change preserves actual bytes and named files" '
		test_when_finished "git -C source -c checkout.reflink=false reset -q --hard base; reflink_stable_source source" &&
		test_when_finished remove_target &&
		private_target &&
		write_script race-hook <<-EOF &&
		test "\$1" = plain || exit 0
		case $change in
		target-write) printf Z | dd of=plain bs=1 count=1 conv=notrunc ;;
		target-replace) mv plain ../held-original; echo replacement >plain ;;
		source-write) printf Z | dd of=../source/plain bs=1 count=1 conv=notrunc ;;
		source-replace) mv ../source/plain ../held-source; echo replacement >../source/plain ;;
		esac
		EOF
		GIT_TEST_REFLINK_RESHARE_HOOK="../race-hook" git -C target worktree reflink --porcelain >out &&
		case $change in
		target-write) printf Z >expect && test_copy_bytes 1 <target/plain >actual && test_cmp expect actual ;;
		target-replace) echo replacement >expect && test_cmp expect target/plain && test_cmp source/plain held-original ;;
		source-write) git -C source show base:plain >expect && test_cmp expect target/plain ;;
		source-replace) test_cmp held-source target/plain && test_grep replacement source/plain ;;
		esac &&
		test_grep "^reason \(representation-differs\|concurrent-change\)$" out
	'
done

test_expect_success RESHARE 'a genuinely racy target uses ordinary verification' '
	test_when_finished remove_target &&
	private_target &&
	test-tool chmtime =+0 target/plain &&
	git -C target add plain &&
	git -C target worktree reflink --porcelain >out &&
	test "$(summary_field content-checked out)" -ge 1 &&
	test_shared source/plain target/plain
'

test_expect_success RESHARE 'an explicit source overrides a stale configured source without settings changes' '
	test_when_finished remove_target &&
	private_target &&
	git -C source config checkout.reflinkSource missing &&
	test_when_finished "git -C source config --unset checkout.reflinkSource" &&
	git -C source worktree reflink --reflink-source=source --porcelain ../target >out &&
	test_shared source/plain target/plain &&
	test "$(git -C source config checkout.reflinkSource)" = missing
'

test_expect_success RESHARE 'NUL path records preserve newline names' '
	test_when_finished "rm -rf names-source names-target" &&
	git init -q names-source && git -C names-source config checkout.reflink false &&
	name="line
break" &&
	make_blob_file "names-source/$name" 64 &&
	git -C names-source add . && git -C names-source commit -qm names &&
	test-tool chmtime =-60 "names-source/$name" &&
	git -C names-source update-index --refresh &&
	git -C names-source worktree add -q --detach --no-reflink ../names-target HEAD &&
	test-tool chmtime =-60 "names-target/$name" &&
	git -C names-target update-index --refresh &&
	git -C names-target worktree reflink --porcelain -z >out &&
	printf "path %s\0" "$name" >needle &&
	perl -0777 -e '\''open my $f, "<", "needle" or die; local $/; my $n=<$f>; my $o=<>; exit(index($o,$n)<0)'\'' out &&
	test_shared "names-source/$name" "names-target/$name"
'

test_expect_success RESHARE 'multiple native ranges and a short EOF preserve and share all bytes' '
	test_when_finished "rm -rf large-source large-target" &&
	git init -q large-source && git -C large-source config checkout.reflink false &&
	test-tool genrandom large 16777339 >large-source/file &&
	git -C large-source add . && git -C large-source commit -qm large &&
	reflink_stable_source large-source &&
	git -C large-source worktree add -q --detach --no-reflink ../large-target HEAD &&
	reflink_stable_source large-target &&
	git -C large-target worktree reflink --porcelain >out &&
	test_cmp large-source/file large-target/file &&
	test_field content-checked 0 out &&
	test_shared large-source/file large-target/file &&
	test_field private-after 0 out
'

test_expect_success RESHARE,SYMLINKS 'tracked symlinks and gitlinks are skipped without recursion' '
	test_when_finished "rm -rf entries-source entries-target" &&
	git init -q entries-source && git -C entries-source config checkout.reflink false &&
	make_blob_file entries-source/plain 64 &&
	ln -s plain entries-source/link &&
	git -C entries-source add . &&
	git -C entries-source update-index --add --cacheinfo 160000,$(git -C source rev-parse HEAD),sub &&
	git -C entries-source commit -qm entries &&
	mkdir entries-source/sub &&
	reflink_stable_source entries-source &&
	git -C entries-source worktree add -q --detach --no-reflink ../entries-target HEAD &&
	reflink_stable_source entries-target &&
	git -C entries-target worktree reflink --porcelain >out &&
	test_field scanned 3 out &&
	test_field skipped 2 out &&
	test -h entries-target/link &&
	test_path_is_dir entries-target/sub &&
	test_shared entries-source/plain entries-target/plain
'

for side in target source
do
	test_expect_success RESHARE,SYMLINKS "re-sharing rejects a symlinked $side parent" '
		test_when_finished "rm -rf path-source path-target outside-dir" &&
		git init -q path-source &&
		git -C path-source config checkout.reflink false &&
		mkdir path-source/dir &&
		make_blob_file path-source/dir/file 64 &&
		git -C path-source add . &&
		git -C path-source commit -qm nested &&
		reflink_stable_source path-source &&
		git -C path-source worktree add -q --detach --no-reflink ../path-target &&
		reflink_stable_source path-target &&
		mv path-$side/dir outside-dir &&
		ln -s ../outside-dir path-$side/dir &&
		test-tool reflink metadata outside-dir/file >before.stat &&
		test-tool reflink private-bytes outside-dir/file >before.usage &&
		git -C path-target worktree reflink --porcelain >out &&
		test-tool reflink metadata outside-dir/file >after.stat &&
		test-tool reflink private-bytes outside-dir/file >after.usage &&
		test_cmp before.stat after.stat &&
		test_cmp before.usage after.usage &&
		test_field reshared 0 out &&
		if test "$side" = target
		then
			test_grep "^reason target-unavailable$" out
		else
			test_grep "^reason no-donor$" out
		fi
	'
done


test_done
