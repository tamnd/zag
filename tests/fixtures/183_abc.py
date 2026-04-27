from abc import ABC, abstractmethod

class Animal(ABC):
    @abstractmethod
    def sound(self):
        pass

    def breathe(self):
        return 'breathes'

class Dog(Animal):
    def sound(self):
        return 'woof'

d = Dog()
print(d.sound())
print(d.breathe())
print(isinstance(d, Animal))
print(isinstance(d, Dog))
print(issubclass(Dog, Animal))
print(Animal.__abstractmethods__)

# abstract class cannot be instantiated
try:
    Animal()
except TypeError as e:
    print('TypeError raised')
