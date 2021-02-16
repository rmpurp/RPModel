//
//  RPModelDatabase.swift
//
//
//  Created by Ryan Purpura on 12/6/20.
//

import Combine
import FMDB
import Foundation
import SQLite3

public protocol DatabaseProxy {
  func executeUpdate(_ sql: String, values: [Any]?) throws
  func executeQuery(_ sql: String, values: [Any]?) throws -> FMResultSet
  var lastInsertRowId: Int64 { get }
}

public final class LiteCrate {
  private var db: FMDatabase!

  private final class TransactionDatabaseProxy: DatabaseProxy {
    var db: FMDatabase
    var isEnabled = true

    init(db: FMDatabase) {
      self.db = db
    }

    func executeUpdate(_ sql: String, values: [Any]?) throws {
      guard isEnabled else {
        fatalError("Do not use this proxy outside of the transaction closure")
      }
      try db.executeUpdate(sql, values: values)
    }

    func executeQuery(_ sql: String, values: [Any]?) throws -> FMResultSet {
      guard isEnabled else {
        fatalError("Do not use this proxy outside of the transaction closure")
      }
      return try db.executeQuery(sql, values: values)
    }

    var lastInsertRowId: Int64 {
      db.lastInsertRowId
    }

  }

  internal let tableChangedPublisher = PassthroughSubject<String, Never>()

  internal let queue: DispatchQueue = DispatchQueue(
    label: "RPModelDispatchQueue",
    qos: .userInteractive,
    attributes: [],
    autoreleaseFrequency: .workItem,
    target: nil)

  let testQueueKey = DispatchSpecificKey<Void>()

  var isOnQueue: Bool { DispatchQueue.getSpecific(key: testQueueKey) != nil }

  var tablesToSignal = Set<String>()

  internal func executeUpdate(_ sql: String, values: [Any]?) throws {
    return try self.queue.sync {
      try db.executeUpdate(sql, values: values)
    }
  }

  internal func executeQuery(_ sql: String, values: [Any]?) throws -> FMResultSet {
    return try self.queue.sync {
      return try db.executeQuery(sql, values: values)
    }
  }

  let updateQueue: DispatchQueue

  public init(
    url: URL?, updateQueue: DispatchQueue = DispatchQueue.main,
    migration: (DatabaseProxy, inout Int64) throws -> Void
  ) rethrows {
    queue.setSpecific(key: testQueueKey, value: ())
    self.updateQueue = updateQueue
    db = FMDatabase(url: url)
    db.open()

    let raw = Unmanaged.passUnretained(self).toOpaque()

    sqlite3_update_hook(
      OpaquePointer(db.sqliteHandle),
      { (aux, type, cDatabaseName, cTableName, rowid) in
        guard let cTableName = cTableName, let aux = aux else { return }

        let liteCrate = Unmanaged<LiteCrate>.fromOpaque(aux).takeUnretainedValue()

        let tableName = String(cString: cTableName)

        NSLog("TABLE NAME: %@", tableName)

        liteCrate.tablesToSignal.insert(tableName)
      }, raw)

    try inTransaction(operation: { db in
      var currentVersion = try getCurrentSchemaVersion()
      try migration(db, &currentVersion)
      try setCurrentSchemaVersion(version: currentVersion)
    })
  }

  public func closeDatabase() {
    queue.sync {
      _ = db?.close()
    }
    db = nil
  }

  public func inTransaction(operation: (DatabaseProxy) throws -> Void) rethrows {
    do {
      try queue.sync {
        db.beginTransaction()

        let databaseProxy = TransactionDatabaseProxy(db: db)
        defer { databaseProxy.isEnabled = false }

        try operation(databaseProxy)
        guard db.commit() else { throw NSError() }

        // Copy so they don't get wiped out by race condition
        let tablesToSignal = self.tablesToSignal
        defer { self.tablesToSignal = [] }

        updateQueue.async { [weak self] in
          guard let self = self else { return }
          tablesToSignal.forEach {
            self.tableChangedPublisher.send($0)
          }
        }
      }
    } catch {
      db.rollback()
    }
  }

  private func getCurrentSchemaVersion() throws -> Int64 {
    dispatchPrecondition(condition: .onQueue(queue))
    let rs = try db.executeQuery("PRAGMA user_version", values: nil)

    if rs.next() {
      let currentVersion = rs.longLongInt(forColumnIndex: 0)
      NSLog("DB at version %d", currentVersion)
      return currentVersion
    } else {
      fatalError("TODO: Change this to reasonable error")
    }
  }

  private func setCurrentSchemaVersion(version: Int64) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    try db.executeUpdate(String(format: "PRAGMA user_version = %lld", version), values: [])
    // Being very careful to avoid injection vulnerability; ? is not valid here.
  }
}