#!/bin/bash

fluid_cmd=`dirname "$0"`/FluidInstance
alice_cmd=`dirname "$0"`/../../../bin/alice

$alice_cmd &
sleep 1
$fluid_cmd
kill $(jobs -p)
