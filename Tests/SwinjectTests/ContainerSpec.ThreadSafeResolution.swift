//
//  ContainerSpec.ThreadSafeResolution.swift
//  Swinject
//
//  Created by Serge Rykovski on 7/29/19.
//  Copyright © 2019 Swinject Contributors. All rights reserved.
//

import Dispatch
import Quick
import Nimble
@testable import Swinject

class ContainerSpec_ThreadSafeResolution: QuickSpec {
    override func spec() {
        describe("Multiple threads") {
            it("can resolve circular dependencies.") {
                let container = Container(threadSafeResolutionEnabled: true) { container in
                    container.register(ParentProtocol.self) { _ in Parent() }
                        .initCompleted { r, s in
                            let parent = s as! Parent
                            parent.child = r.resolve(ChildProtocol.self)
                        }
                        .inObjectScope(.graph)
                    container.register(ChildProtocol.self) { _ in Child() }
                        .initCompleted { r, s in
                            let child = s as! Child
                            child.parent = r.resolve(ParentProtocol.self)!
                        }
                        .inObjectScope(.graph)
                    }
                
                onMultipleThreads {
                    let parent = container.resolve(ParentProtocol.self) as! Parent
                    let child = parent.child as! Child
                    expect(child.parent as? Parent === parent).to(beTrue()) // Workaround for crash in Nimble
                }
            }
            it("can access parent and child containers without dead lock.") {
                let runInObjectScope = { (scope: ObjectScope) in
                    let parentContainer = Container(threadSafeResolutionEnabled: true) { container in
                        container.register(Animal.self) { _ in Cat() }
                            .inObjectScope(scope)
                    }
                    let childContainer = Container(parent: parentContainer, threadSafeResolutionEnabled: true)
                    
                    onMultipleThreads(actions: [
                        { _ = parentContainer.resolve(Animal.self) as! Cat },    // swiftlint:disable:this opening_brace
                        { _ = childContainer.resolve(Animal.self) as! Cat }
                        ])
                }
                
                runInObjectScope(.transient)
                runInObjectScope(.graph)
                runInObjectScope(.container)
            }
            it("uses distinct graph identifier") {
                var graphs = Set<GraphIdentifier>()
                let container = Container(threadSafeResolutionEnabled: true) {
                    $0.register(Dog.self) {
                        graphs.insert(($0 as! Container).currentObjectGraph!)
                        return Dog()
                    }
                    }
                
                onMultipleThreads { _ = container.resolve(Dog.self) }
                
                expect(graphs.count) == totalThreads
            }
        }
        describe("Nested resolve") {
            it("can make it without deadlock") {
                let container = Container(threadSafeResolutionEnabled: true)
                container.register(ChildProtocol.self) { _ in  Child() }
                container.register(ParentProtocol.self) { _ in
                    Parent(child: container.resolve(ChildProtocol.self)!)
                }
                
                let queue = DispatchQueue(
                    label: "SwinjectTests.ContainerSpec_ThreadSafeResolution.Queue", attributes: .concurrent
                )
                waitUntil(timeout: 2.0) { done in
                    queue.async {
                        _ = container.resolve(ParentProtocol.self)
                        done()
                    }
                }
            }
        }
    }
}

fileprivate final class Counter {
    enum Status {
        case underMax, reachedMax
    }
    
    private var max: Int
    private let lock = DispatchQueue(label: "SwinjectTests.ContainerSpec_ThreadSafeResolution.Counter.Lock", attributes: [])
    var count = 0
    
    init(max: Int) {
        self.max = max
    }
    
    @discardableResult
    func increment() -> Status {
        var status = Status.underMax
        lock.sync {
            self.count += 1
            if self.count >= self.max {
                status = .reachedMax
            }
        }
        return status
    }
}

private let totalThreads = 500 // 500 threads are enough to get fail unless the container is thread safe.

private func onMultipleThreads(action: @escaping () -> Void) {
    onMultipleThreads(actions: [action])
}

private func onMultipleThreads(actions: [() -> Void]) {
    waitUntil(timeout: 2.0) { done in
        let queue = DispatchQueue(
            label: "SwinjectTests.ContainerSpec_ThreadSafeResolution.Queue",
            attributes: .concurrent
        )
        let counter = Counter(max: actions.count * totalThreads)
        for _ in 0..<totalThreads {
            actions.forEach { action in
                queue.async {
                    action()
                    if counter.increment() == .reachedMax {
                        done()
                    }
                }
            }
        }
    }
}
