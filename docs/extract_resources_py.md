# get_loadoffs(c, d)

c is a tuple of two integers, d is a tuple of two integers
x and y are the first and second elements of c, respectively
x and y are shifted right by 4 bits
x and y are added to the first and second elements of d, respectively
x and y are bitwise ANDed with 0x3f
x and y are shifted left by 7 and 1 bits, respectively
x and y are bitwise ORed together
the result is returned

c is a tuple of two integers
d is a tuple of two integers
x is the first integer in c shifted right 4 bits
y is the second integer in c shifted right 4 bits
x is incremented by the first integer in d
y is incremented by the second integer in d
return the bitwise OR of the bitwise AND of y with 0x3f shifted left 7 bits and the bitwise AND of x with 0x3f shifted left 1 bit

# map32_to_map16

The function prints the map32_to_map16 table to the file f.
The table is stored in the ROM in 4 different places, each of them containing a quarter of the table.
The function iterates over the table, reading each entry from the ROM and printing it to the file.

# get_exit_datas

## get_special_exit_info

The function takes `room_index` as an argument, and then returns a dictionary with the following keys:

|                    |                                 |
| ------------------ | ------------------------------- |
| `dir`              | the direction of the exit (0-3) |
| `spr_gfx`          | the sprite graphics index       |
| `aux_gfx`          | the auxiliary graphics index    |
| `pal_bg`           | the background palette index    |
| `pal_spr`          | the sprite palette index        |
| `top`              | the top edge of the exit        |
| `bottom`           | the bottom edge of the exit     |
| `left`             | the left edge of the exit       |
| `right`            | the right edge of the exit      |
| `left_edge_of_map` | the left edge of the map        |
| `unk4`             | unknown                         |
| `unk6`             | unknown                         |
| `unk5`             | unknown                         |
| `unk7`             | unknown                         |

The function gets the room index and subtracts 0x180 from it.
It then uses the result to index into a series of tables.
The first table is at 0x82E801 and contains the direction of the exit.
The second table is at 0x82E811 and contains the sprite graphics index.
The third table is at 0x82E821 and contains the auxiliary graphics index.
The fourth table is at 0x82E831 and contains the background palette index.
The fifth table is at 0x82E841 and contains the sprite palette index.
The sixth table is at 0x82E6E1 and contains the top edge of the exit.
The seventh table is at 0x82E701 and contains the bottom edge of the exit.
The eighth table is at 0x82E721 and contains the left edge of the exit.
The ninth table is at 0x82E741 and contains the right edge of the exit.
The tenth table is at 0x82E7E1 and contains the left edge of the map.
The eleventh table is at 0x82E761 and contains an unknown value.
The twelfth table is at 0x82E781 and contains an unknown value.
The thirteenth table is at 0x82E7A1 and contains an unknown value.
The fourteenth table is at 0x82E7C1 and contains an unknown value.
//
The function returns a dictionary with the values from the tables.