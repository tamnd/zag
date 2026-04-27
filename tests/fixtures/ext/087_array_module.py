# array module

import array

# Basic array creation
a = array.array('i', [1, 2, 3, 4, 5])
print(a.typecode)                                 # i
print(len(a))                                     # 5
print(a[0])                                       # 1
print(a[-1])                                      # 5

# append and extend
a.append(6)
print(a[-1])                                      # 6
a.extend([7, 8])
print(list(a))                                    # [1, 2, 3, 4, 5, 6, 7, 8]

# pop
val = a.pop()
print(val)                                        # 8
val2 = a.pop(0)
print(val2)                                       # 1
print(list(a))                                    # [2, 3, 4, 5, 6, 7]

# insert
a.insert(0, 1)
print(list(a))                                    # [1, 2, 3, 4, 5, 6, 7]

# remove
a.remove(4)
print(list(a))                                    # [1, 2, 3, 5, 6, 7]

# index
print(a.index(5))                                 # 3

# count
a2 = array.array('i', [1, 2, 1, 3, 1])
print(a2.count(1))                                # 3

# reverse
a3 = array.array('i', [1, 2, 3])
a3.reverse()
print(list(a3))                                   # [3, 2, 1]

# Float array
f = array.array('d', [1.1, 2.2, 3.3])
print(round(f[0], 1))                             # 1.1
print(round(sum(f), 1))                           # 6.6

# tobytes and frombytes
b = a3.tobytes()
a4 = array.array('i')
a4.frombytes(b)
print(list(a4))                                   # [3, 2, 1]

# tolist
print(a3.tolist())                                # [3, 2, 1]

# Different typecodes
for tc in ['b', 'B', 'h', 'H', 'i', 'I', 'l', 'L', 'q', 'Q', 'f', 'd']:
    arr = array.array(tc, [0, 1, 2])
    print(tc, len(arr))

print('done')
