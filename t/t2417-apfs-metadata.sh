#!/bin/sh

test_description='APFS allocation oracle and descriptor clone repair metadata'
. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

test_lazy_prereq PYTHON3 '
	python3 -c "import ctypes, sys; sys.exit(sys.version_info < (3, 9))"
'

test_expect_success MACOS,PYTHON3,REFLINK 'native allocation oracle and clone repair metadata' '
	python3 "$TEST_DIRECTORY/lib-reflink/apfs-metadata.py" \
		--after "$GIT_BUILD_DIR" --root "$TRASH_DIRECTORY/native-fixture"
'

test_expect_success MACOS,PYTHON3,REFLINK 're-share ignores only kernel provenance and verifies copied metadata' '
	python3 "$TEST_DIRECTORY/lib-reflink/apfs-reshare-provenance.py" \
		--build "$GIT_BUILD_DIR" --root "$TRASH_DIRECTORY/reshare-fixture"
'

test_done
