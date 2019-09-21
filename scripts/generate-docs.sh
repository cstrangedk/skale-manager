#!/bin/bash

OUTDIR=docs/

rm -rf "$OUTDIR"
solidity-docgen -o "$OUTDIR" --contract-pages