# functools.wraps and partial advanced

import functools

# wraps preserves metadata
def decorator(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        return fn(*args, **kwargs)
    return wrapper

@decorator
def my_func(x, y):
    """My docstring."""
    return x + y

print(my_func.__name__)                            # my_func
print(my_func.__doc__)                             # My docstring.
print(my_func(3, 4))                               # 7

# Stacking decorators
def add_prefix(prefix):
    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            result = fn(*args, **kwargs)
            return f'{prefix}{result}'
        return wrapper
    return decorator

@add_prefix('Result: ')
def compute(x):
    return x * 2

print(compute(5))                                  # Result: 10
print(compute.__name__)                            # compute

# partial advanced
def log(level, msg, prefix=''):
    return f'[{level}]{prefix}: {msg}'

warn = functools.partial(log, 'WARN')
error = functools.partial(log, 'ERROR', prefix='ERR')

print(warn('something happened'))                  # [WARN]: something happened
print(error('critical failure'))                   # [ERROR]ERR: critical failure

# partial with keywords
def power(base, exponent, mod=None):
    if mod:
        return pow(base, exponent, mod)
    return base ** exponent

square = functools.partial(power, exponent=2)
cube = functools.partial(power, exponent=3)
print(square(5))                                   # 25
print(cube(3))                                     # 27

# partial.func, partial.args, partial.keywords
print(warn.func is log)                            # True
print(warn.args)                                   # ('WARN',)
print(error.keywords)                              # {'prefix': 'ERR'}

# reduce with initial value
nums = [1, 2, 3, 4, 5]
print(functools.reduce(lambda a, b: a + b, nums, 100))  # 115

# reduce on empty list with initial
print(functools.reduce(lambda a, b: a + b, [], 0))     # 0

# cmp_to_key
def compare(a, b):
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

nums2 = [3, 1, 4, 1, 5, 9, 2, 6]
print(sorted(nums2, key=functools.cmp_to_key(compare)))  # [1, 1, 2, 3, 4, 5, 6, 9]

print('done')
