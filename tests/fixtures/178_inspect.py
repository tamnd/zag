import inspect

def hello(x, y=5):
    pass

class Foo:
    x = 1
    y = 2
    def bar(self):
        pass

# isfunction, isclass, isbuiltin, ismodule
print(inspect.isfunction(hello))
print(inspect.isclass(Foo))
print(inspect.isbuiltin(len))
print(inspect.ismodule(inspect))

# ismethod on bound method
f = Foo()
print(inspect.ismethod(f.bar))

# isroutine covers functions and builtins
print(inspect.isroutine(hello))
print(inspect.isroutine(len))

# getmembers returns sorted (name, value) pairs
members = dict(inspect.getmembers(Foo))
print(members['x'])
print(members['y'])
