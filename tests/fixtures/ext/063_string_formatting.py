# String formatting

# f-strings with expressions
x = 42
print(f'{x}')                                       # 42
print(f'{x * 2}')                                   # 84
print(f'value is {x}')                              # value is 42

# Nested f-string
name = 'World'
print(f'Hello, {name}!')                            # Hello, World!
print(f'{name.upper()} rocks')                      # WORLD rocks

# str.format
print('{} + {} = {}'.format(1, 2, 3))              # 1 + 2 = 3
print('{0} {1} {0}'.format('a', 'b'))              # a b a
print('{name} is {age}'.format(name='Alice', age=30))  # Alice is 30

# str methods
s = 'Hello, World!'
print(s.upper())                                    # HELLO, WORLD!
print(s.lower())                                    # hello, world!
print(s.title())                                    # Hello, World!
print(s.replace('World', 'Python'))                # Hello, Python!
print(s.startswith('Hello'))                       # True
print(s.endswith('!'))                             # True
print(s.find('World'))                             # 7
print(s.count('l'))                                # 3

# split and join
parts = 'a,b,c,d'.split(',')
print(parts)                                       # ['a', 'b', 'c', 'd']
print('-'.join(parts))                             # a-b-c-d

# strip variants
padded = '  hello  '
print(padded.strip())                              # hello
print(padded.lstrip())                             # 'hello  '
print(padded.rstrip())                             # '  hello'

# center, ljust, rjust
print('hi'.center(10))                            #     hi
print('hi'.ljust(10) + '|')                       # hi        |
print('hi'.rjust(10) + '|')                       #         hi|

# encode/decode round-trip
b = 'hello'.encode('utf-8')
print(b)                                           # b'hello'
print(b.decode('utf-8'))                           # hello

# zfill
print('42'.zfill(6))                               # 000042
print('-42'.zfill(6))                              # -00042

# isdigit, isalpha, isalnum
print('123'.isdigit())                             # True
print('abc'.isalpha())                             # True
print('abc123'.isalnum())                          # True
print('abc 123'.isalnum())                         # False

print('done')
