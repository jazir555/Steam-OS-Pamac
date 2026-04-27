#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
ps aux | grep -E 'diverse|pamac|podman' | grep -v grep | head -10
