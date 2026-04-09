OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    /* Instruction RAM - 64KB for CoreMark */
    . = 0x00000000;
    .text : ALIGN(4)
    {
        *(.text*)
        *(.rodata*)
    }

    /* Data RAM - 16KB */
    . = 0x00010000;
    .data : ALIGN(4)
    {
        *(.data*)
        *(.sdata*)
    }

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    }
}
