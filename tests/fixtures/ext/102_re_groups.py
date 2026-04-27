# re module - groups and named groups

import re

# Basic groups
m = re.match(r'(\d+)-(\d+)-(\d+)', '2024-01-15')
print(m.group(0))                                  # 2024-01-15
print(m.group(1))                                  # 2024
print(m.group(2))                                  # 01
print(m.group(3))                                  # 15
print(m.groups())                                  # ('2024', '01', '15')

# Named groups
m2 = re.match(r'(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})', '2024-03-20')
print(m2.group('year'))                            # 2024
print(m2.group('month'))                           # 03
print(m2.group('day'))                             # 20
print(m2.groupdict())                              # {'year': '2024', 'month': '03', 'day': '20'}

# findall with groups
text = 'price: $10.99, sale: $5.50, tax: $1.25'
prices = re.findall(r'\$(\d+\.\d+)', text)
print(prices)                                      # ['10.99', '5.50', '1.25']

# sub with backreference
result = re.sub(r'(\w+) (\w+)', r'\2 \1', 'hello world')
print(result)                                      # world hello

# sub with function
def double_digit(m):
    return str(int(m.group()) * 2)

result2 = re.sub(r'\d+', double_digit, 'a1 b2 c3')
print(result2)                                     # a2 b4 c6

# split with groups
parts = re.split(r'(\s+)', 'one  two   three')
print([p for p in parts if p.strip()])            # ['one', 'two', 'three']

# Non-capturing group
m3 = re.match(r'(?:https?|ftp)://([\w.]+)', 'https://example.com/path')
print(m3.group(1))                                 # example.com

# Optional group
m4 = re.match(r'(\w+)(?:\.(\w+))?', 'hello.world')
print(m4.group(1))                                 # hello
print(m4.group(2))                                 # world

m5 = re.match(r'(\w+)(?:\.(\w+))?', 'hello')
print(m5.group(1))                                 # hello
print(m5.group(2))                                 # None

print('done')
