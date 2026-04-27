# string module

import string

# Constants
print(string.ascii_lowercase)      # abcdefghijklmnopqrstuvwxyz
print(string.ascii_uppercase)      # ABCDEFGHIJKLMNOPQRSTUVWXYZ
print(string.digits)               # 0123456789
print(string.hexdigits)            # 0123456789abcdefABCDEF
print(string.punctuation)         # !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
print(string.whitespace.strip())   # (whitespace chars)
print(string.ascii_letters[:5])    # abcde

# Template
t = string.Template('Hello, $name! You have $count messages.')
result = t.substitute(name='Alice', count=5)
print(result)                       # Hello, Alice! You have 5 messages.

t2 = string.Template('$greeting, ${name}!')
print(t2.substitute(greeting='Hi', name='Bob'))   # Hi, Bob!

# safe_substitute (doesn't raise on missing keys)
t3 = string.Template('Hello, $name! $missing')
print(t3.safe_substitute(name='Alice'))  # Hello, Alice! $missing

# capwords
print(string.capwords('hello world foo'))   # Hello World Foo
print(string.capwords('  hello   world  ')) # Hello World

# Formatter
fmt = string.Formatter()
result2 = fmt.format('{0} and {1}', 'foo', 'bar')
print(result2)                      # foo and bar

result3 = fmt.format('{name} is {age}', name='Alice', age=30)
print(result3)                      # Alice is 30

# Using string constants for filtering
text = 'Hello, World! 123'
letters_only = ''.join(c for c in text if c in string.ascii_letters)
print(letters_only)                 # HelloWorld

digits_only = ''.join(c for c in text if c in string.digits)
print(digits_only)                  # 123

print('done')
