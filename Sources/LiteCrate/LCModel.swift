//
//  File.swift
//
//
//  Created by Ryan Purpura on 12/6/20.
//

import Combine
import FMDB
import Foundation

public protocol LCModel: Identifiable, Equatable, Codable {
  override var id: ID { get set }
}

extension LCModel {
  private var insertValues: (columnString: String, placeholders: String, values: [Any]) {
    let encoder = DatabaseEncoder()
    try! self.encode(to: encoder)
    let columnsToValue = encoder.columnToKey
    // If there is an error here, it will be caught and resolved during developement
    
    let columns = [String](columnsToValue.keys)
    let columnString = columns.joined(separator: ",")
    let placeholders = String(String(repeating: "?,", count: columnsToValue.count).dropLast())
    let values = columns.map { columnsToValue[$0]! }
    return (columnString, placeholders, values)
  }
}

extension LCModel {
  public static var tableName: String { String(describing: Self.self) }
  
  internal static func tableUpdatedPublisher(
    in crate: LiteCrate, notifyOn queue: DispatchQueue = DispatchQueue.main
  ) -> AnyPublisher<Void, Never> {
    crate.tableChangedPublisher
      .filter { $0 == Self.tableName }
      .map { _ in () }
      .assertNoFailure()
      .eraseToAnyPublisher()
  }
  
  /// Creates a publisher that fetches all items that match the where condition given.
  /// - Parameter sqlWhereClause: SQL WHERE clause. If null, fetches all.
  /// - Returns: publisher that publishes the stuff.
  public static func publisher(
    in crate: LiteCrate, forAllWhere sqlWhereClause: String? = nil, values: [Any]? = nil
  )
  -> AnyPublisher<[Self], Never> where Self: LCModel
  {
    Just(())
      .receive(on: crate.updateQueue)
      .append(Self.tableUpdatedPublisher(in: crate))
      // TODO: Come up with better error handling model
      .map { _ in
        (try? Self.fetchAll(from: crate, forAllWhere: sqlWhereClause, values: values)) ?? []
      }
      .eraseToAnyPublisher()
  }
  
  public static func publisher(in crate: LiteCrate, forPrimaryKey primaryKey: ID) -> AnyPublisher<
    Self?, Never
  > {
    Just(())
      .receive(on: crate.updateQueue)
      .append(Self.tableUpdatedPublisher(in: crate))
      .map {
        _ in try? Self.fetch(from: crate, with: primaryKey)
      }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
  
  public func updatePublisher(in crate: LiteCrate) -> AnyPublisher<Self?, Never> {
    Self.tableUpdatedPublisher(in: crate)
      .map { _ in try? Self.fetch(from: crate, with: id) }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
  
  public static func fetch(from crate: CrateProxy, with primaryKey: ID) throws -> Self? {
    return try Self.fetchAll(from: crate, forAllWhere: "id = ?", values: [primaryKey]).first
  }
  
  /// Blocking call to fetch
  public static func fetchAll(
    from crate: CrateProxy, forAllWhere sqlWhereClause: String? = nil, values: [Any]? = nil
  )
  throws -> [Self]
  {
    // TODO: Properly rewrite query if where clause is null
    let sqlWhereClause = sqlWhereClause ?? "1=1"

    return try crate.executeQuery(
      "SELECT * FROM \(Self.tableName) WHERE \(sqlWhereClause)",
      values: values) { (rs) -> [Self] in
      let decoder = DatabaseDecoder(resultSet: rs)
      var returnValue = [Self]()
      while rs.next() {
        try returnValue.append(Self(from: decoder))
      }
      return returnValue
    }
  }
}

// MARK: - CRUD
extension LCModel {
  public func save(in crate: CrateProxy) -> Never where ID == Any? {
    fatalError("Only Int64? is allowed as optional id type")
  }
  
  mutating public func save(in crate: CrateProxy) throws where ID == Int64? {
    let (columnString, placeholders, values) = insertValues
    
    try crate.executeUpdate(
      "INSERT OR REPLACE INTO \(Self.tableName)(\(columnString)) VALUES (\(placeholders)) ",
      values: values)
    id = crate.lastInsertRowId
  }
  
  public func save(in crate: CrateProxy) throws {
    let (columnString, placeholders, values) = insertValues
    try crate.executeUpdate(
      "INSERT OR REPLACE INTO \(Self.tableName)(\(columnString)) VALUES (\(placeholders)) ",
      values: values)
  }
  
  public static func delete(from crate: CrateProxy, with id: ID) throws {
    try crate.executeUpdate("DELETE FROM \(Self.tableName) WHERE id = ?", values: [id])
  }
  
  public static func delete(from crate: CrateProxy, allWhere sqlWhereClause: String? = nil, values: [Any]? = nil) throws {
    let sqlWhereClause = sqlWhereClause ?? "1=1"
    try crate.executeUpdate("DELETE FROM \(Self.tableName) WHERE \(sqlWhereClause)", values: values)
  }
  
  public func delete(from crate: CrateProxy) throws {
    try crate.executeUpdate("DELETE FROM \(Self.tableName) WHERE id = ?", values: [id])
  }
}

// MARK: - Int64? PK Special Handling
extension LCModel where ID == Int64? {
  public func updatePublisher(in crate: LiteCrate) -> AnyPublisher<Self?, Never> {
    guard id != nil else {
      fatalError("id must not be nil to use this publisher; you need to save first")
    }
    return Self.publisher(in: crate, forPrimaryKey: self.id)
  }
}
