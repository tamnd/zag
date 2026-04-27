# Comprehensive string methods

s = 'Hello, World!'

# Case
print(s.upper())                                      # HELLO, WORLD!
print(s.lower())                                      # hello, world!
print(s.title())                                      # Hello, World!
print(s.swapcase())                                   # hELLO, wORLD!

# Strip
print('  hello  '.strip())                            # hello
print('  hello  '.lstrip())                           # hello  (trailing spaces remain)
print('  hello  '.rstrip())                           # '  hello'
print('xxxhelloxxx'.strip('x'))                       # hello

# Split/Join
words = 'one two three'.split()
print(words)                                          # ['one', 'two', 'three']
csv = 'a,b,c,d'.split(',')
print(csv)                                            # ['a', 'b', 'c', 'd']
print('a,b,c,d'.split(',', 2))                        # ['a', 'b', 'c,d']

print('-'.join(['a', 'b', 'c']))                      # a-b-c
print(' '.join(words))                                # one two three

# Find/Index
print('hello world'.find('world'))                    # 6
print('hello world'.find('xyz'))                      # -1
print('hello world'.index('world'))                   # 6

# Replace
print('hello world'.replace('world', 'Python'))       # hello Python
print('aabbcc'.replace('b', 'X', 1))                  # aaXbcc

# Starts/Ends
print('hello'.startswith('he'))                       # True
print('hello'.endswith('lo'))                         # True
print('hello'.startswith(('hi', 'he')))               # True

# Count
print('abcabc'.count('abc'))                          # 2
print('hello'.count('l'))                             # 2

# Format
print('{} + {} = {}'.format(1, 2, 3))                 # 1 + 2 = 3
print('{name} is {age}'.format(name='Alice', age=30)) # Alice is 30
print(f'{42:04d}')                                    # 0042
print(f'{3.14:.2f}')                                  # 3.14

# Encode/Decode
b = 'hello'.encode('utf-8')
print(b)                                              # b'hello'
print(b.decode('utf-8'))                              # hello

# zfill, ljust, rjust, center
print('42'.zfill(5))                                  # 00042
print('hi'.ljust(8, '-'))                             # hi------
print('hi'.rjust(8, '-'))                             # ------hi
print('hi'.center(8, '-'))                            # ---hi---

# isdigit, isalpha, isalnum
print('123'.isdigit())                                # True
print('abc'.isalpha())                                # True
print('abc123'.isalnum())                             # True
print('abc 123'.isalnum())                            # False

# splitlines
text = 'line1\nline2\nline3'
print(text.splitlines())                              # ['line1', 'line2', 'line3']

print('done')
