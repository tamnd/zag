import functools

# Basic decorator
def uppercase(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        result = func(*args, **kwargs)
        return result.upper()
    return wrapper

@uppercase
def greet(name):
    return f'hello {name}'

print(greet('world'))                                 # HELLO WORLD
print(greet.__name__)                                 # greet

# Decorator with arguments
def repeat(n):
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for _ in range(n):
                result = func(*args, **kwargs)
            return result
        return wrapper
    return decorator

@repeat(3)
def say(msg):
    print(msg)
    return msg

r = say('hi')                                         # hi\nhi\nhi
print(r)                                              # hi

# Class decorator
def singleton(cls):
    instances = {}
    @functools.wraps(cls)
    def get_instance(*args, **kwargs):
        if cls not in instances:
            instances[cls] = cls(*args, **kwargs)
        return instances[cls]
    return get_instance

@singleton
class Config:
    def __init__(self, value=42):
        self.value = value

c1 = Config()
c2 = Config()
print(c1 is c2)                                       # True
print(c1.value)                                       # 42

# Stacked decorators
def add_prefix(prefix):
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            return prefix + func(*args, **kwargs)
        return wrapper
    return decorator

def add_suffix(suffix):
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            return func(*args, **kwargs) + suffix
        return wrapper
    return decorator

@add_prefix('[')
@add_suffix(']')
def bracket(s):
    return s

print(bracket('hello'))                               # [hello]

# lru_cache
@functools.lru_cache(maxsize=128)
def fib(n):
    if n < 2:
        return n
    return fib(n-1) + fib(n-2)

print(fib(10))                                        # 55
print(fib(20))                                        # 6765

print('done')
