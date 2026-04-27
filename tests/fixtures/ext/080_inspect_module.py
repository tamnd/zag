# inspect module basics

import inspect

# isfunction, isclass
def my_func(x, y=10):
    """A sample function."""
    return x + y

class MyClass:
    def method(self):
        pass

print(inspect.isfunction(my_func))                 # True
print(inspect.isfunction(lambda x: x))             # True
print(inspect.isclass(MyClass))                    # True
print(inspect.isclass(my_func))                    # False
print(inspect.ismethod(MyClass().method))          # True

# getmembers
class Demo:
    x = 1
    def foo(self):
        pass

members = dict(inspect.getmembers(Demo))
print('x' in members)                              # True
print(members['x'])                                # 1

# isbuiltin
print(inspect.isbuiltin(len))                      # True
print(inspect.isbuiltin(my_func))                  # False

# ismodule
import math
print(inspect.ismodule(math))                      # True

# isgeneratorfunction
def gen_fn():
    yield 1

print(inspect.isgeneratorfunction(gen_fn))         # True
print(inspect.isgeneratorfunction(my_func))        # False

# isgenerator
gen = gen_fn()
print(inspect.isgenerator(gen))                    # True
print(inspect.isgenerator(my_func))                # False

# isroutine
print(inspect.isroutine(my_func))                  # True
print(inspect.isroutine(len))                      # True
print(inspect.isroutine(42))                       # False

# isframe (our interp may not have frame objects)
print(inspect.isframe(None))                       # False

print('done')
