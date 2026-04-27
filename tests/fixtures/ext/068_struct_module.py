# struct module

import struct

# Basic pack/unpack
packed = struct.pack('!I', 1234567890)
print(len(packed))                                  # 4
unpacked = struct.unpack('!I', packed)
print(unpacked[0])                                  # 1234567890

# Multiple values
data = struct.pack('!HHI', 1, 2, 3)
print(struct.unpack('!HHI', data))                 # (1, 2, 3)

# Little-endian
packed_le = struct.pack('<i', -42)
print(struct.unpack('<i', packed_le)[0])           # -42

# Float
packed_f = struct.pack('!f', 3.14)
val = struct.unpack('!f', packed_f)[0]
print(round(val, 2))                               # 3.14

# calcsize
print(struct.calcsize('!I'))                       # 4
print(struct.calcsize('!HHI'))                     # 8
print(struct.calcsize('!d'))                       # 8

# Struct object (compiled)
s = struct.Struct('!IHH')
print(s.size)                                      # 8
packed2 = s.pack(100, 200, 300)
print(s.unpack(packed2))                           # (100, 200, 300)

# Characters and strings
packed3 = struct.pack('4s', b'abcd')
print(struct.unpack('4s', packed3)[0])             # b'abcd'

# Bool
packed4 = struct.pack('?', True)
print(struct.unpack('?', packed4)[0])              # True

# Long long (8 bytes)
packed5 = struct.pack('!q', -1234567890123)
print(struct.unpack('!q', packed5)[0])             # -1234567890123

# Big-endian double
packed6 = struct.pack('!d', 3.14159)
val2 = struct.unpack('!d', packed6)[0]
print(round(val2, 5))                              # 3.14159

print('done')
