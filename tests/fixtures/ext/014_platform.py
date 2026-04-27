import platform

# All these return strings -- check type only for determinism
s = platform.system()
print(isinstance(s, str))                              # True
print(len(s) > 0)                                      # True

m = platform.machine()
print(isinstance(m, str))                              # True

v = platform.python_version()
print(isinstance(v, str))                              # True
print(v.startswith('3.'))                              # True

impl = platform.python_implementation()
print(isinstance(impl, str))                           # True
print(impl == 'CPython')                               # True

# python_version_tuple returns a tuple of 3 strings
t = platform.python_version_tuple()
print(isinstance(t, tuple))                            # True
print(len(t) == 3)                                     # True
print(t[0] == '3')                                     # True

# node() returns hostname string
n = platform.node()
print(isinstance(n, str))                              # True

# architecture() returns a tuple of two strings
arch = platform.architecture()
print(isinstance(arch, tuple))                         # True
print(len(arch) == 2)                                  # True

print('done')
