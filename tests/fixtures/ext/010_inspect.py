import inspect

# isfunction
def my_func():
    pass

print(inspect.isfunction(my_func))                     # True
print(inspect.isfunction(len))                         # False
print(inspect.isfunction(42))                          # False

# isclass
class MyClass:
    pass

print(inspect.isclass(MyClass))                        # True
print(inspect.isclass(my_func))                        # False
print(inspect.isclass(42))                             # False

# isbuiltin
print(inspect.isbuiltin(len))                          # True
print(inspect.isbuiltin(print))                        # True
print(inspect.isbuiltin(my_func))                      # False

# ismodule
import math
print(inspect.ismodule(math))                          # True
print(inspect.ismodule(MyClass))                       # False

# ismethod
class Counter:
    def inc(self):
        pass

obj = Counter()
print(inspect.ismethod(obj.inc))                       # True
print(inspect.ismethod(Counter.inc))                   # False

# getmembers - just check it returns a list of (name, value) pairs
members = inspect.getmembers(math, inspect.isbuiltin)
print(isinstance(members, list))                       # True
print(len(members) > 0)                                # True
print(isinstance(members[0], tuple))                   # True

print('done')
