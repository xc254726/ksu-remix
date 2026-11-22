SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help fetch config kernel pack all clean doctor ksud manager apk dist

help:
	@echo "ksu-remix —— KernelSU 二改构建"
	@echo ""
	@echo "内核侧"
	@echo "  make doctor   检查构建环境（clang/依赖/参数）"
	@echo "  make fetch    拉内核源码 + 集成 KernelSU"
	@echo "  make config   生成 .config 并锁定版本串 / 页大小"
	@echo "  make kernel   编译内核并校验 vermagic"
	@echo "  make pack     重打包 boot.img"
	@echo "  make all      fetch + config + kernel"
	@echo ""
	@echo "APK 侧"
	@echo "  make ksud     编译 Rust 版 ksud（APK 里 libksud.so 的来源）"
	@echo "  make manager  编译 rue 管理器 APK（未注入 ksud）"
	@echo "  make apk      manager + ksud + 注入重签，出最终 APK"
	@echo "  make dist     汇总 out/ 下所有产物清单"
	@echo ""
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

ksud:
	@bash scripts/build-ksud.sh

manager:
	@bash scripts/build-manager.sh

apk: manager ksud
	@bash scripts/pack-apk.sh

dist:
	@echo "== out/ 产物 =="
	@find out -maxdepth 2 -type f \( -name '*.img' -o -name '*.apk' -o -name '*.ko' -o -name 'Image*' \) -printf '%10s  %p\n' 2>/dev/null | sort -k2 || true

clean:
	rm -rf build out
	@echo "已清理 build/ out/"
