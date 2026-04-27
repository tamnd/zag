import sys

# Basic sys attributes
print(isinstance(sys.version, str))                   # True
print(sys.version_info.major == 3)                    # True
print(sys.version_info.minor >= 0)                    # True
print(isinstance(sys.platform, str))                  # True
print(sys.maxsize > 0)                                # True

# sys.argv
print(isinstance(sys.argv, list))                     # True

# sys.path
print(isinstance(sys.path, list))                     # True

# sys.modules
print(isinstance(sys.modules, dict))                  # True
print('sys' in sys.modules)                           # True

# sys.stdin, sys.stdout, sys.stderr
print(sys.stdout is not None)                         # True
print(sys.stderr is not None)                         # True

# sys.byteorder
print(sys.byteorder in ('little', 'big'))             # True

# sys.getrecursionlimit
limit = sys.getrecursionlimit()
print(limit > 0)                                      # True

# sys.setrecursionlimit
sys.setrecursionlimit(500)
print(sys.getrecursionlimit() == 500)                 # True

# sys.exc_info
try:
    raise ValueError('test')
except ValueError:
    t, v, tb = sys.exc_info()
    print(t is ValueError)                            # True
    print(str(v))                                     # test

print('done')
