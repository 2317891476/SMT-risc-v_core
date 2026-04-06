OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        __text_start = .;
        *(.text.init)
        *(.text*)
        __text_end = .;
    } > IROM

    .rodata : AT (0x00100000)
    {
        __rodata_start = .;
        *(.rodata*)
        __rodata_end = .;
    } > DRAM

    .data : AT (0x00110000)
    {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        __data_end = .;
    } > DRAM

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > DRAM

    _end = .;
    PROVIDE(end = .);
    __stack_top = ORIGIN(DRAM) + LENGTH(DRAM);
    PROVIDE(_stack = __stack_top);
}
