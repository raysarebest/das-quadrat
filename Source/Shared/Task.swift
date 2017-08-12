//
//  Task.swift
//  Quadrat
//
//  Created by Constantine Fry on 26/10/14.
//  Copyright (c) 2014 Constantine Fry. All rights reserved.
//

import Foundation

public enum FoursquareResponse {
    case result(Dictionary<String, String>)
    case error(NSError)
}

open class Task {
    fileprivate var task: URLSessionTask?
    fileprivate weak var session: Session?
    fileprivate let completionHandler: ResponseClosure?
    
    var request: Request
    
    /** The identifier of network activity. */
    var networkActivityId: Int?
    
    init (session: Session, request: Request, completionHandler: ResponseClosure?) {
        self.session = session
        self.request = request
        self.completionHandler = completionHandler
    }
    
    func constructURLSessionTask() {fatalError("Use subclasses!")}
    
    /** Starts the task. */
    open func start() {
        if self.session == nil {
            fatalError("No session for this task.")
        }
        if self.task == nil {
            self.constructURLSessionTask()
        }
        if let task = self.task {
            task.resume()
            networkActivityId = session!.networkActivityController?.beginNetworkActivity()
        }
    }
    
    /** 
        Cancels the task.
        Returns error with NSURLErrorDomain and code NSURLErrorCancelled in `completionHandler`.
        Hint: use `isCancelled()` on `Response` object.
    */
    open func cancel() {
        self.task?.cancel()
        self.task = nil
    }
}

open class DataTask: Task {
    override func constructURLSessionTask() {
        let URLsession = self.session?.URLSession
        self.task = URLsession?.dataTask(with: request.URLRequest(), completionHandler: {
            (data, response, error) -> Void in
            self.session?.networkActivityController?.endNetworkActivity(self.networkActivityId)
            
            let result = Result.resultFromURLSessionResponse(response, data: data, error: error as NSError?)
            self.session?.processResult(result)
            self.session?.completionQueue.addOperation {
                self.completionHandler?(result)
                return Void()
            }
        }) 
    }
}

open class PersistentTask: DataTask{
    open let cacheLocation: URL
    open let maximumCacheAge: TimeInterval
    private static let cacheLastUpdatedKey = "LastCacheUpdate"
    open var isCacheStale: Bool{
        get{
            return PersistentTask.isCacheStale(for: cacheLocation, maxAge: maximumCacheAge)
        }
    }
    // I wish Swift would let you capture self in a closure in an initializer when just the instance members it needs are initialized, instead of strictly *all* of them
    private static func isCacheStale(for url: URL, maxAge: TimeInterval) -> Bool{
        guard let cache = NSDictionary(contentsOf: url) else{
            return true
        }
        guard let lastUpdateInterval = cache[PersistentTask.cacheLastUpdatedKey] as? TimeInterval else{
            return true
        }
        let nextUpdate = Date(timeInterval: maxAge, since: Date(timeIntervalSince1970: lastUpdateInterval))
        return Calendar.current.isDateInToday(nextUpdate) || Calendar.current.compare(nextUpdate, to: Date(), toGranularity: .day) == .orderedAscending
    }
    init(session: Session, request: Request, completionHandler: ResponseClosure?, cacheLocation: URL, cacheAge: TimeInterval){
        self.cacheLocation = cacheLocation
        self.maximumCacheAge = cacheAge
        let callback: ResponseClosure = {(result: Result) in
            if PersistentTask.isCacheStale(for: cacheLocation, maxAge: cacheAge){
                guard var response = result.response else{
                    return
                }
                response[PersistentTask.cacheLastUpdatedKey] = Date().timeIntervalSince1970 as AnyObject
                let _ = (response as NSDictionary).write(to: cacheLocation, atomically: true)
            }
            completionHandler?(result)
        }
        super.init(session: session, request: request, completionHandler: callback)
    }
    convenience init(session: Session, request: Request, completionHandler: ResponseClosure?, cacheName: String, cacheAge: TimeInterval){
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else{
            fatalError("Could not locate the caches directory")
        }
        if let cache = URL(string: cacheName + ".plist", relativeTo: caches){
            self.init(session: session, request: request, completionHandler: completionHandler, cacheLocation: cache, cacheAge: cacheAge)
        }
        else{
            self.init(session: session, request: request, completionHandler: completionHandler, cacheLocation: URL(string: "FoursquareCache.plist", relativeTo: caches)!, cacheAge: cacheAge)
        }
    }

    override open func start() -> Void{
        // Check if the cache exists and is valid. If so, just call the completion handler with a Result constructed from the cache. If not, just call super
        if isCacheStale{
            super.start()
        }
        else{
            guard let completion = completionHandler else{
                super.start()
                return
            }
            guard let cachedResponse = NSDictionary(contentsOf: cacheLocation) else{
                super.start()
                return
            }
            let spoofed = Result()
            spoofed.HTTPStatusCode = 200 // In case external code is checking for success via status code
            spoofed.response = cachedResponse as? [String: AnyObject]
            completion(spoofed)
        }
    }
}

class UploadTask: Task {
    var  fileURL: URL?
    
    override func constructURLSessionTask() {
        // swiftlint:disable force_cast
        let mutableRequest = (self.request.URLRequest() as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        
        let boundary = UUID().uuidString
        let contentType = "multipart/form-data; boundary=" + boundary
        mutableRequest.addValue(contentType, forHTTPHeaderField: "Content-Type")
        let body = NSMutableData()
        let appendStringBlock = {
            (string: String) in
            body.append(string.data(using: String.Encoding.utf8, allowLossyConversion: false)!)
        }
        let extention = self.fileURL!.pathExtension
        appendStringBlock("\r\n--\(boundary)\r\n")
        appendStringBlock("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.\(extention)\"\r\n")
        appendStringBlock("Content-Type: image/\(extention)\r\n\r\n")
        if let imageData = try? Data(contentsOf: self.fileURL!) {
            body.append(imageData)
        } else {
            fatalError("Can't read data at URL: \(self.fileURL!)")
        }
        appendStringBlock("\r\n--\(boundary)--\r\n")
        
        self.task = self.session?.URLSession.uploadTask(with: mutableRequest as URLRequest, from: body as Data, completionHandler: {
            (data, response, error) -> Void in
            self.session?.networkActivityController?.endNetworkActivity(self.networkActivityId)
            
            let result = Result.resultFromURLSessionResponse(response, data: data, error: error as NSError?)
            self.session?.processResult(result)
            self.session?.completionQueue.addOperation {
                self.completionHandler?(result)
                return Void()
            }
        }) 
    }
}
