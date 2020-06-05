#!/bin/sh
# echo "CORONA_ROOT: ${CORONA_ROOT}"
if [ ! -d "${CORONA_ROOT}" ]
then
    echo "error: Corona Native has not been setup.  Run 'Native/SetupCoronaNative.app' in your Corona install to set it up" >&2

    exit 1
else
    echo "Building with Corona Native from $(readlink "${CORONA_ROOT}")"
fi
