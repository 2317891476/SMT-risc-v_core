import os
import re
import shutil
import logging
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class adam_riscv(pluginTemplate):
    __model__ = "adam_riscv"
    __version__ = "1.0.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')

        if config is None:
            raise RuntimeError("Config not found")

        self.num_jobs = str(config.get('jobs', 1))
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        
        self.target_run = config.get('target_run', '1') != '0'

        # Project root (3 levels up from plugin path)
        self.project_root = os.path.normpath(os.path.join(self.pluginpath, '..', '..', '..'))

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.archtest_env = archtest_env

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')
        self.isa = 'rv32im'  # AdamRiscv supports RV32IM

    def runTests(self, testList):
        make = utils.makeUtil(makefilePath=os.path.join(self.work_dir, "Makefile.adam_riscv"))
        make.makeCommand = 'make -k -j' + self.num_jobs

        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            
            elf = os.path.join(test_dir, "test.elf")
            sig_file = os.path.join(test_dir, "adam_riscv.signature")
            compile_macros = ' -D' + ' -D'.join(testentry['macros']) if testentry['macros'] else ''

            # GCC compile command
            compile_cmd = (
                'riscv-none-elf-gcc -march=rv32im -mabi=ilp32 '
                '-static -mcmodel=medany -fvisibility=hidden '
                '-nostdlib -nostartfiles -g '
                f'-T {self.pluginpath}/env/link.ld '
                f'-I {self.pluginpath}/env '
                f'-I {self.archtest_env} '
                f'{test} -o {elf} {compile_macros}'
            )

            # Convert ELF to Verilog hex
            inst_hex = os.path.join(test_dir, "inst.hex")
            data_hex = os.path.join(test_dir, "data.hex")
            
            objcopy_cmd = (
                f'riscv-none-elf-objcopy -O verilog {elf} {inst_hex} && '
                f'riscv-none-elf-objcopy -O verilog --only-section=.data {elf} {data_hex} || true'
            )

            if self.target_run:
                # Iverilog compile
                vvp_out = os.path.join(test_dir, "sim.vvp")
                rtl_dir = os.path.join(self.project_root, 'module', 'CORE', 'RTL_V1_2')
                libs_dir = os.path.join(self.project_root, 'libs', 'REG_ARRAY', 'SRAM')
                tb_file = os.path.join(self.pluginpath, 'env', 'tb_riscof.sv')
                
                iverilog_cmd = (
                    f'iverilog -g2012 -o {vvp_out} -s tb_riscof '
                    f'-I {rtl_dir} {rtl_dir}/*.v {libs_dir}/ram_bfm.v {tb_file} 2>&1'
                )
                
                # VVP run (with timeout)
                vvp_cmd = f'timeout 60 vvp {vvp_out} +signature={sig_file} 2>&1 || true'
                
                # Create signature file from memory dump
                sig_create = f'python {self.pluginpath}/env/extract_signature.py {test_dir} {sig_file}'
            else:
                vvp_cmd = 'echo "Skip run"'
                sig_create = 'echo "Skip signature"'

            # Build make target
            execute = (
                f'@cd {test_dir} && '
                f'{compile_cmd} && '
                f'{objcopy_cmd} && '
                f'{iverilog_cmd if self.target_run else ""} && '
                f'{vvp_cmd} && '
                f'{sig_create}'
            )

            make.add_target(execute)

        make.execute_all(self.work_dir)

        if not self.target_run:
            raise SystemExit(0)
