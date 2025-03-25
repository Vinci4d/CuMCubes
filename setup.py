# Copyright (c) Zhihao Liang. All rights reserved.
import os
from typing import List
from setuptools import setup

from torch.utils.cpp_extension import BuildExtension, CUDAExtension

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))


def get_requirements(filename: str = "requirements.txt") -> List[str]:
    assert os.path.exists(filename), f"{filename} not exists"
    with open(filename, "r") as f:
        content = f.read()
    lines = content.split("\n")
    requirements_list = list(filter(lambda x: x != "" and not x.startswith("#"), lines))
    return requirements_list


def get_version() -> str:
    version_file = os.path.join("cumcubes", "version.py")
    with open(version_file, "r", encoding="utf-8") as f:
        exec(compile(f.read(), version_file, "exec"))
    return locals()["__version__"]


def get_extensions():
    extra_compile_args = {
        "cxx": ["-O3"],
        "nvcc": [
            "-O3",
            "--use_fast_math",
            "-gencode=arch=compute_90,code=sm_90",
            "-gencode=arch=compute_89,code=sm_89",
            "-gencode=arch=compute_87,code=sm_87",
            "-gencode=arch=compute_86,code=sm_86",
            "-gencode=arch=compute_80,code=sm_80",
        ],
    }

    ext_modules = [
        CUDAExtension(
            name="cumcubes.src",
            sources=[
                "cumcubes/src/bindings.cpp",
                "cumcubes/src/cumcubes.cpp",
                "cumcubes/src/cumcubes_kernel.cu",
            ],
            include_dirs=[os.path.join(ROOT_DIR, "cumcubes", "include")],
            optional=False,
            extra_compile_args=extra_compile_args,
            extra_link_args=["-Wl,--no-as-needed"],
        ),
    ]
    return ext_modules


setup(
    name="cumcubes",
    version=get_version(),
    description="CUDA implementation of marching cubes",
    url="https://github.com/lzhnb/CuMCubes",
    long_description=open("README.md").read(),
    ext_modules=get_extensions(),
    setup_requires=["pybind11>=2.5.0"],
    packages=["cumcubes", "cumcubes.src"],
    cmdclass={"build_ext": BuildExtension},
    zip_safe=False,
)
