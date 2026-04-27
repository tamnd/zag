# Closures and scoping

# Basic closure
def make_adder(n):
    def adder(x):
        return x + n
    return adder

add5 = make_adder(5)
add10 = make_adder(10)
print(add5(3))                                        # 8
print(add10(3))                                       # 13
print(add5(add10(1)))                                 # 16

# Closure captures by reference
def make_counter():
    count = 0
    def increment():
        nonlocal count
        count += 1
        return count
    def reset():
        nonlocal count
        count = 0
    return increment, reset

inc, rst = make_counter()
print(inc())                                          # 1
print(inc())                                          # 2
print(inc())                                          # 3
rst()
print(inc())                                          # 1

# Closures in a loop (captured variable)
funcs = []
for i in range(5):
    def f(x=i):  # default arg captures current value
        return x
    funcs.append(f)
print([f() for f in funcs])                          # [0, 1, 2, 3, 4]

# Nested closures
def outer(x):
    def middle(y):
        def inner(z):
            return x + y + z
        return inner
    return middle

fn = outer(1)(2)
print(fn(3))                                          # 6

# Global vs local
x = 'global'

def show_x():
    return x

def change_x():
    global x
    x = 'changed'

print(show_x())                                       # global
change_x()
print(show_x())                                       # changed

# Class-based closure equivalent
class Multiplier:
    def __init__(self, factor):
        self.factor = factor
    def __call__(self, x):
        return x * self.factor

double = Multiplier(2)
triple = Multiplier(3)
print(double(5))                                      # 10
print(triple(5))                                      # 15

# Closure with mutable default
def accumulate(lst=None):
    if lst is None:
        lst = []
    def add(x):
        lst.append(x)
        return lst[:]
    return add

acc1 = accumulate()
acc2 = accumulate()
acc1(1)
acc1(2)
acc2(10)
print(acc1(3))                                        # [1, 2, 3]
print(acc2(20))                                       # [10, 20]

print('done')
