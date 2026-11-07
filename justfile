set shell := ["nu", "-c"]

default:
    @just --list

test:
    nu tests/run.nu
