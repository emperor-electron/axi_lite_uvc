# Corsair example register map

Created with [Corsair](https://github.com/esynr3z/corsair) v1.0.4.

## Conventions

| Access mode | Description               |
| :---------- | :------------------------ |
| rw          | Read and Write            |
| rw1c        | Read and Write 1 to Clear |
| rw1s        | Read and Write 1 to Set   |
| ro          | Read Only                 |
| roc         | Read Only to Clear        |
| roll        | Read Only / Latch Low     |
| rolh        | Read Only / Latch High    |
| wo          | Write only                |
| wosc        | Write Only / Self Clear   |

## Register map summary

Base address: 0x00000000

| Name                     | Address    | Description |
| :---                     | :---       | :---        |
| [ID](#id)                | 0x000      | Identification. Constant, so a correct read proves the AXI4-Lite path reaches this block. |
| [CTRL](#ctrl)            | 0x004      | Main control. Deliberately mixes a byte-aligned field, an unaligned field and an enumerated field, so every field-write strategy the UVC can pick is exercised by one register. |
| [STATUS](#status)        | 0x008      | Read-only status driven by hardware. |
| [IRQ](#irq)              | 0x00c      | Write-1-to-clear interrupt flags. A read-modify-write here would clear flags nobody asked to clear, which is the hazard the UVC's field_write() avoids. |
| [CMD](#cmd)              | 0x010      | Write-only command. Cannot be read back, so a field write here cannot read-modify-write and must use the shadow value. |
| [SCRATCH](#scratch)      | 0x014      | Plain read/write word, for a whole-register access that needs no field handling at all. |
| [EVENT](#event)          | 0x018      | Event counter that clears when read. Reading it to service one field is destructive, so the UVC will not read-modify-write this register. |

## ID

Identification. Constant, so a correct read proves the AXI4-Lite path reaches this block.

Address offset: 0x000

Reset value: 0xa7110001


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| MAGIC            | 31:16  | ro              | 0xa711     | Always 0xA711. |
| VERSION          | 15:0   | ro              | 0x0001     | Map version. |

Back to [Register map](#register-map-summary).

## CTRL

Main control. Deliberately mixes a byte-aligned field, an unaligned field and an enumerated field, so every field-write strategy the UVC can pick is exercised by one register.

Address offset: 0x004

Reset value: 0x00008000


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| -                | 31:28  | -               | 0x0        | Reserved |
| THRESH           | 27:16  | rw              | 0x000      | Straddles byte lane 2 and 3, so a write to this field alone needs a read-modify-write. |
| GAIN             | 15:8   | rw              | 0x80       | Byte-aligned on purpose: a write to this field alone needs no read. |
| -                | 7:3    | -               | 0x0        | Reserved |
| MODE             | 2:1    | rw              | 0x0        | Operating mode. |
| ENABLE           | 0      | rw              | 0x0        | Enable the block. |

Enumerated values for CTRL.MODE.

| Name             | Value   | Description |
| :---             | :---    | :---        |
| IDLE             | 0x0    | Do nothing. |
| STREAM           | 0x1    | Continuous streaming. |
| SINGLE           | 0x2    | One frame then stop. |
| LOOPBACK         | 0x3    | Echo input to output. |

Back to [Register map](#register-map-summary).

## STATUS

Read-only status driven by hardware.

Address offset: 0x008

Reset value: 0x00000000


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| -                | 31:8   | -               | 0x000000   | Reserved |
| ERRCODE          | 7:4    | ro              | 0x0        | Last error. |
| -                | 3:1    | -               | 0x0        | Reserved |
| BUSY             | 0      | ro              | 0x0        | Block is busy. |

Enumerated values for STATUS.ERRCODE.

| Name             | Value   | Description |
| :---             | :---    | :---        |
| NONE             | 0x0    | No error. |
| OVERFLOW         | 0x1    | Input overflowed. |
| UNDERFLOW        | 0x2    | Input underflowed. |

Back to [Register map](#register-map-summary).

## IRQ

Write-1-to-clear interrupt flags. A read-modify-write here would clear flags nobody asked to clear, which is the hazard the UVC's field_write() avoids.

Address offset: 0x00c

Reset value: 0x00000000


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| -                | 31:2   | -               | 0x0000000  | Reserved |
| ERROR            | 1      | rw1c            | 0x0        | Error occurred. |
| DONE             | 0      | rw1c            | 0x0        | Operation completed. |

Back to [Register map](#register-map-summary).

## CMD

Write-only command. Cannot be read back, so a field write here cannot read-modify-write and must use the shadow value.

Address offset: 0x010

Reset value: 0x00000000


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| -                | 31:25  | -               | 0x0        | Reserved |
| FLAG             | 24     | wo              | 0x0        | Single bit at the top of the word. Write-only and not byte-aligned, so writing it alone can only be done from the shadow value. |
| ARG              | 23:8   | wo              | 0x0000     | Command argument. |
| OPCODE           | 7:0    | wo              | 0x00       | Command opcode. |

Back to [Register map](#register-map-summary).

## SCRATCH

Plain read/write word, for a whole-register access that needs no field handling at all.

Address offset: 0x014

Reset value: 0x00000000


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| VALUE            | 31:0   | rw              | 0x00000000 | Anything you like. |

Back to [Register map](#register-map-summary).

## EVENT

Event counter that clears when read. Reading it to service one field is destructive, so the UVC will not read-modify-write this register.

Address offset: 0x018

Reset value: 0x00000000


| Name             | Bits   | Mode            | Reset      | Description |
| :---             | :---   | :---            | :---       | :---        |
| -                | 31:17  | -               | 0x000      | Reserved |
| ARM              | 16     | rw              | 0x0        | Plain control bit sharing the register with a read-clear field. |
| -                | 15:8   | -               | 0x00       | Reserved |
| COUNT            | 7:0    | roc             | 0x00       | Events since the last read. Cleared by the read itself. |

Back to [Register map](#register-map-summary).
