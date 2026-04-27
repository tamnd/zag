from abc import ABC, abstractmethod, ABCMeta

# Basic abstract class
class Shape(ABC):
    @abstractmethod
    def area(self):
        pass

    @abstractmethod
    def perimeter(self):
        pass

    def describe(self):
        return f'Shape with area {self.area()}'

class Circle(Shape):
    def __init__(self, radius):
        self.radius = radius

    def area(self):
        return 3.14159 * self.radius ** 2

    def perimeter(self):
        return 2 * 3.14159 * self.radius

c = Circle(5)
print(round(c.area(), 2))                             # 78.54
print(round(c.perimeter(), 2))                        # 31.42
print(c.describe()[:5])                               # Shape

# Cannot instantiate abstract class
try:
    s = Shape()
    print('no error')
except TypeError:
    print('TypeError raised')                          # TypeError raised

# ABCMeta
class Animal(metaclass=ABCMeta):
    @abstractmethod
    def speak(self):
        pass

class Dog(Animal):
    def speak(self):
        return 'Woof'

d = Dog()
print(d.speak())                                      # Woof

# isinstance with ABC
print(isinstance(c, Shape))                           # True
print(isinstance(d, Animal))                          # True

print('done')
