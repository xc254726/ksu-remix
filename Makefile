SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help fetch config kernel pack all clean doctor

help:
	@echo "ksu-remix —— KernelSU 二改构建"
	@echo ""
	@echo "  make doctor   检查构建环境（clang/依赖/参数）"
	@echo "  make fetch    拉内核源码 + 集成 KernelSU"
	@echo "  make config   生成 .config 并锁定版本串 / 页大小"
	@echo "  make kernel   编译内核并校验 vermagic"
	@echo "  make pack     重打包 boot.img"
	@echo "  make all      fetch + config + kernel"
	@echo "  make clean    清掉 build/ 与 out/"

doctor:
	@bash scripts/doctor.sh

fetch:
	@bash scripts/fetch.sh

config:
	@bash scripts/config.sh

kernel:
	@bash scripts/build.sh

pack:
	@bash scripts/pack.sh

all: fetch config kernel

clean:
	rm -rf build out
	@echo "已清理 build/ out/"
