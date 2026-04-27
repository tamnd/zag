from abc import ABC, ABCMeta, abstractmethod

# Basic abstract class via ABC
class Shape(ABC):
    @abstractmethod
    def area(self):
        pass

    @abstractmethod
    def perimeter(self):
        pass

class Circle(Shape):
    def __init__(self, r):
        self.r = r
    def area(self):
        return self.r * self.r
    def perimeter(self):
        return 2 * self.r

c = Circle(3)
print(c.area())                                        # 9
print(c.perimeter())                                   # 6
print(isinstance(c, Shape))                            # True
print(isinstance(c, ABC))                              # True

# Cannot instantiate abstract class
try:
    Shape()
except TypeError:
    print('cannot instantiate abstract')               # cannot instantiate abstract

# ABCMeta directly
class Animal(metaclass=ABCMeta):
    @abstractmethod
    def speak(self):
        pass

class Dog(Animal):
    def speak(self):
        return 'woof'

d = Dog()
print(d.speak())                                       # woof
print(isinstance(d, Animal))                           # True

# register() -- virtual subclass
class MyList:
    pass

Animal.register(MyList)
print(issubclass(MyList, Animal))                      # True
ml = MyList()
print(isinstance(ml, Animal))                          # True

# __subclasshook__
class Sized(ABC):
    @classmethod
    def __subclasshook__(cls, C):
        if cls is Sized:
            return hasattr(C, '__len__')
        return NotImplemented

print(issubclass(list, Sized))                         # True
print(issubclass(int, Sized))                          # False

print('done')
