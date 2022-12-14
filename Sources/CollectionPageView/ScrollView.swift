//
//  File.swift
//
//
//  Created by Leo Mehlig on 21.11.22.
//

import UIKit
import SwiftUI
import Combine
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "PageView"
)
class ScrollPageView<Cell: UIView, Value: Hashable>:
    UIScrollView, UIScrollViewDelegate
where Value: Comparable, Value: Strideable, Value.Stride == Int, Value: CustomStringConvertible {
    
    
    let publisher: CurrentValueSubject<Value, Never>


    private var selected: Value {
        didSet {
            if oldValue != self.selected {
                DispatchQueue.main.async {
                    self.publisher.send(self.selected)
                }
            }
        }
    }
    
    var configureCell: (Cell, Value) -> Void
    
    private var pages: [Value] = []
    private var nextValue: Value?
    private var bufferSize = 2
    private var views: [Value: Cell] = [:]
    private var centerPage: Value
    
    private func updatePages() {
        if let next = self.nextValue, next != self.centerPage {
            if self.centerPage > next {
                self.pages = Array(next.advanced(by: -bufferSize + 1)...next)
                + Array(self.centerPage...self.centerPage.advanced(by: bufferSize))
            } else {
                self.pages = Array(self.centerPage.advanced(by: -bufferSize)...self.centerPage)
                + Array(next...next.advanced(by: bufferSize - 1))
            }
        } else {
            self.pages = Array(self.centerPage.advanced(by: -bufferSize)...self.centerPage.advanced(by: bufferSize))
        }
    }
    
    init(selected: Value,
         configureCell: @escaping (Cell, Value) -> Void) {
        self.configureCell = configureCell
        self.publisher = CurrentValueSubject(selected)
        self.selected = selected
        self.centerPage = selected
        super.init(frame: .zero)
        self.showsHorizontalScrollIndicator = false
        self.showsVerticalScrollIndicator = false
        self.isPagingEnabled = true
        self.backgroundColor = .clear
        self.delegate = self
        self.updatePages()
        self.updateViews()
        self.contentOffset = self.offset(for: self.selected)
    }
    
    var animationCounter = 0
    func select(value: Value) {
        if value != self.nextValue && (self.selected != value || self.nextValue != nil) {
            self.nextValue = value
            DispatchQueue.main.async {
                self.publisher.send(value)
            }
            self.updatePages()
            self.updateViews()
            logger.info("Selected \(value.description) manually")
            self.animationCounter += 1
            self.setContentOffset(self.offset(for: value), animated: true)
        }
    }
    
    func updateViews() {
        var reusable = Array(self.views.filter({ !self.pages.contains($0.key) }).values)
        var updated: [Value: Cell] = [:]
        for value in pages {
            if let existing = self.views[value] {
                updated[value] = existing
            } else {
                let new: Cell
                if let reused = reusable.popLast() {
                    new = reused
                } else {
                    new = Cell(frame: .zero)
                    self.addSubview(new)
                }
                
                self.configureCell(new, value)
                updated[value] = new
            }
        }
        reusable.forEach {
            $0.removeFromSuperview()
        }
        self.views = updated
        self.forceRelayout = true
        self.setNeedsLayout()
    }
    
    func offset(for value: Value) -> CGPoint {
        let index = self.pages.firstIndex(of: value) ?? 0
        return .init(x: self.bounds.width * CGFloat(index), y: 0)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var oldSize = CGSize.zero
    var forceRelayout = false
    
    override func layoutSubviews() {
        super.layoutSubviews()
        if oldSize != self.bounds.size || forceRelayout {
            logger.info("Relayout (forced=\(self.forceRelayout))")
            forceRelayout = false
            let oldOffset = self.contentOffset.x
            
            self.contentSize = CGSize(width: self.bounds.width * CGFloat(self.views.count),
                                      height: self.bounds.height)
            for (index, value) in self.pages.enumerated() {
                let offset = CGPoint(x: self.bounds.width * CGFloat(index),
                                     y: 0)
                self.views[value]?.frame = CGRect(origin: offset, size: self.bounds.size)
            }
            if self.oldSize.width <= 0 {
                self.contentOffset = self.offset(for: self.selected)
            } else {
                self.contentOffset.x = oldOffset / oldSize.width * self.bounds.width
            }
            self.oldSize = self.bounds.size
        }
        self.updateSelection()
        self.recenter()
    }
    
    func updateSelection(force: Bool = false) {
        guard self.bounds.width > 0 else {
            return
        }
        let offset = self.offset(for: self.selected).x
        guard force
                || self.contentOffset.x <= offset - self.bounds.width
                || self.contentOffset.x >= offset + self.bounds.width else {
            return
        }
        let index = Int(round(self.contentOffset.x / self.bounds.width))
        if self.pages.indices ~= index {
            if self.nextValue == nil || self.nextValue == self.pages[index] {
                logger.info("Changing page from \(self.selected.description) to \(self.pages[index].description) with offset=\(self.contentOffset.x / self.bounds.width), next=\(self.nextValue?.description ?? "none"), force=\(force)")
                self.nextValue = nil
                self.selected = self.pages[index]
            }
        }
    }
    
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.nextValue = nil
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.updateSelection(force: true)
        self.ensurePaging()
        self.recenter(force: true)
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        self.animationCounter -= 1
        logger.info("Scrolling ended next=\(self.nextValue?.description ?? "none"), counter=\(self.animationCounter)")
        guard self.animationCounter == 0 else {
            return
        }
        self.updateSelection(force: true)
        self.ensurePaging()
        self.recenter(force: true)
    }
    
    func ensurePaging() {
        if abs(self.contentOffset.x - self.offset(for: self.selected).x) > 1 {
            logger.info("Fixed paging from \(self.contentOffset.x) to \(self.offset(for: self.selected).x), next=\(self.nextValue?.description ?? "none")")
            self.contentOffset.x = self.offset(for: self.selected).x
        }
    }
               
    func recenter(force: Bool = false) {
        guard self.bounds.width > 0 else {
            return
        }
        let centerOffset = self.offset(for: centerPage)
        let selectedOffset = self.offset(for: selected)
        if abs(centerOffset.x - selectedOffset.x) / self.bounds.width >= CGFloat(self.bufferSize - 1)
            || (force && self.centerPage != self.selected) {
            logger.info("Recentered from \(self.centerPage) to \(self.selected)")
            self.centerPage = self.selected
            self.updatePages()
            self.updateViews()
            let newOffset = self.offset(for: selected)
            self.contentOffset.x = self.contentOffset.x + (newOffset.x - selectedOffset.x)
        }
    }
}
