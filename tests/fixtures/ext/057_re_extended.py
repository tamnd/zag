# re module extended

import re

# Basic match and search
m = re.match(r'\d+', '123abc')
print(m.group())                                     # 123

m2 = re.search(r'\d+', 'abc123def')
print(m2.group())                                    # 123

# findall
nums = re.findall(r'\d+', 'a1b22c333')
print(nums)                                          # ['1', '22', '333']

# sub
result = re.sub(r'\d+', 'NUM', 'a1b22c333')
print(result)                                        # aNUMbNUMcNUM

# split
parts = re.split(r'\s+', 'hello   world  foo')
print(parts)                                         # ['hello', 'world', 'foo']

# Groups
m3 = re.match(r'(\w+)\s+(\w+)', 'John Doe')
print(m3.group(1))                                   # John
print(m3.group(2))                                   # Doe
print(m3.groups())                                   # ('John', 'Doe')

# Named groups
m4 = re.match(r'(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})', '2024-01-15')
print(m4.group('year'))                              # 2024
print(m4.group('month'))                             # 01
print(m4.group('day'))                               # 15

# Flags
m5 = re.search(r'hello', 'Hello World', re.IGNORECASE)
print(m5.group())                                    # Hello

# compile
pattern = re.compile(r'\b\w{4}\b')
words4 = pattern.findall('This is a test with some four letter words')
print(words4)                                        # ['This', 'test', 'with', 'some', 'four']

# No match
m7 = re.search(r'xyz', 'hello')
print(m7)                                            # None

# fullmatch
m8 = re.fullmatch(r'\d+', '12345')
print(m8.group())                                    # 12345

m9 = re.fullmatch(r'\d+', '123abc')
print(m9)                                            # None

print('done')
