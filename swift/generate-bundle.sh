#!/bin/bash -eu
# imports
. `dirname $0`/common/helpers.sh

# vars
opts=(
--template swift.yaml.template
--path $0
)

# defaults
#parameters[]=
overlays+=( swift.yaml )

list_overlays ()
{
    echo "Supported overlays:"
    sed -r 's/.+\s+(--[[:alnum:]\-]+\*?).+/\1/g;t;d' `basename $0`| \
        egrep -v "\--list-overlays"
}


while (($# > 0))
do
    case "$1" in
        --graylog)
            overlays+=( "graylog.yaml ")
            ;;
        --ha)
            get_units $1 __NUM_SWIFT_PROXY_UNITS__ 3
            overlays+=( "swift-ha.yaml" )
            ;;
        --list-overlays)
            list_overlays
            exit
            ;;
        *)
            opts+=( $1 )
            ;;
    esac
    shift
done

generate
