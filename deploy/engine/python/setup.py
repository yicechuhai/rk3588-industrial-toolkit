"""
setup.py for rknn-engine Python package.

This package provides Python bindings for the RK3588 zero-copy
NPU inference engine (libengine.so).

Two build modes:

1. On-device (RK3588 native) — full build:
   python setup.py build_ext --inplace

2. Cross-compilation (aarch64-linux-gnu):
   export RKNN_TOOLCHAIN=/path/to/aarch64-linux-gnu
   python setup.py build_ext --inplace

Requirements:
  - pybind11 (pip install pybind11)
  - CMake >= 3.16
  - C++17 compiler
  - librknnrt.so, librga.so, yaml-cpp (RK3588 toolchain)

Author: RK3588 Industrial Toolkit
"""

import os
import subprocess
import sys
import sysconfig

from pathlib import Path

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext


# ── Paths ──
HERE = Path(__file__).parent.resolve()              # deploy/engine/python/
ENGINE_DIR = HERE.parent                             # deploy/engine/
ENGINE_SRC = ENGINE_DIR / "src"
ENGINE_INCLUDE = ENGINE_DIR / "include"


class CMakeBuildExt(build_ext):
    """Custom build_ext that uses CMake to compile libengine.so and
    the pybind11 module, then copies the resulting .pyd/.so into place."""

    def build_extension(self, ext: Extension) -> None:
        build_dir = Path(self.build_temp)
        build_dir.mkdir(parents=True, exist_ok=True)

        # ── Detect platform / toolchain ──
        is_aarch64 = any(
            arch in os.uname().machine.lower()
            for arch in ("aarch64", "arm64")
        )

        cmake_args = [
            f"-DCMAKE_BUILD_TYPE={os.environ.get('CMAKE_BUILD_TYPE', 'Release')}",
            f"-DPYTHON_EXECUTABLE={sys.executable}",
        ]

        if not is_aarch64:
            # Cross-compilation: assume aarch64-linux-gnu toolchain
            toolchain = os.environ.get("RKNN_TOOLCHAIN", "aarch64-linux-gnu")
            cmake_args.extend([
                f"-DCMAKE_C_COMPILER={toolchain}-gcc",
                f"-DCMAKE_CXX_COMPILER={toolchain}-g++",
                f"-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER",
                f"-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY",
                f"-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
                f"-DCMAKE_SYSTEM_NAME=Linux",
                f"-DCMAKE_SYSTEM_PROCESSOR=aarch64",
            ])

        # ── Run CMake ──
        subprocess.check_call(
            ["cmake", str(ENGINE_DIR)] + cmake_args,
            cwd=build_dir,
        )

        # ── Build ──
        jobs = os.cpu_count() or 2
        subprocess.check_call(
            ["cmake", "--build", build_dir, "--target", "rknn_engine_python",
             "--", f"-j{jobs}"],
        )

        # ── Locate built module ──
        # The CMake pybind11 target produces rknn_engine{ext_suffix}.so
        ext_suffix = sysconfig.get_config_var("EXT_SUFFIX") or ".so"
        module_name = f"rknn_engine{ext_suffix}"
        built = build_dir / module_name

        if not built.exists():
            # Try alternative name from pybind11
            built = build_dir / "python" / module_name

        if not built.exists():
            raise RuntimeError(
                f"Cannot find built extension '{module_name}' in {build_dir}. "
                "Check CMake output above."
            )

        # ── Copy to output directory ──
        dest = Path(self.get_ext_fullpath(ext.name))
        dest.parent.mkdir(parents=True, exist_ok=True)
        self.copy_file(str(built), str(dest))


# ── Extension descriptor (minimal — real work in CMakeBuildExt) ──
engine_ext = Extension(
    "rknn_engine",
    sources=[
        str(ENGINE_DIR / "python" / "bindings.cpp"),
        str(ENGINE_SRC / "engine.cpp"),
        str(ENGINE_SRC / "model_loader.cpp"),
        str(ENGINE_SRC / "preprocessor.cpp"),
        str(ENGINE_SRC / "postprocessor.cpp"),
    ],
    include_dirs=[
        str(ENGINE_INCLUDE),
    ],
    libraries=["rknnrt", "rga", "yaml-cpp"],
    language="c++",
    extra_compile_args=["-std=c++17", "-O2", "-fPIC"],
)


# ── Setup ──
setup(
    name="rknn-engine",
    version="1.0.0",
    description="Python bindings for RK3588 zero-copy NPU inference engine",
    long_description=(HERE / "README.md").read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
    author="RK3588 Industrial Toolkit",
    url="https://github.com/yicechuhai/rk3588-industrial-toolkit",
    license="MIT",
    python_requires=">=3.8",
    install_requires=[
        "numpy>=1.20",
        "pybind11>=2.10",
    ],
    ext_modules=[engine_ext],
    cmdclass={"build_ext": CMakeBuildExt},
    zip_safe=False,
)
