//
//  favoriteModel.swift
//  SimpleLiveTVOS
//
//  Created by pc on 2024/1/12.
//

import Foundation
import LiveParse
import SwiftUI
import CloudKit
import Observation
import SimpleToast


@Observable
class AppFavoriteModel {
    let actor = FavoriteStateModel()
    var roomList: [LiveModel] = []
    var isLoading: Bool = false
    var cloudKitReady: Bool = false
    var cloudKitStateString: String = "正在检查状态"
    
    //Toast
    var showToast: Bool = false
    var toastTitle: String = ""
    var toastTypeIsSuccess: Bool = false
    var toastOptions = SimpleToastOptions(
        alignment: .topLeading, hideAfter: 1.5
    )
    
    @MainActor
    func syncWithActor() async {
        self.isLoading = true
        await actor.getState()
        self.cloudKitReady = await actor.cloudKitReady
        self.cloudKitStateString = await actor.cloudKitStateString
        if self.cloudKitReady {
            do {
                self.roomList = try await actor.syncStreamerLiveStates()
                isLoading = false
            }catch {
                isLoading = false
            }
            
        }
    }
    
    func addFavorite(room: LiveModel) async throws {
        try await CloudSQLManager.saveRecord(liveModel: room)
        self.roomList.append(room)
    }
    
    func removeFavoriteRoom(room: LiveModel) async throws {
        try await CloudSQLManager.deleteRecord(liveModel: room)
        let index = roomList.firstIndex(of: room)
        if index != nil {
            self.roomList.remove(at: index!)
        }
    }
    
    //MARK: 操作相关
    func showToast(_ success: Bool, title: String, hideAfter: TimeInterval? = 1.5) {
        showToast = true
        toastTitle = title
        toastTypeIsSuccess = success
        toastOptions = SimpleToastOptions(
            alignment: .topLeading, hideAfter: hideAfter
        )
    }
}

actor FavoriteStateModel: ObservableObject {

    var isLoading: Bool = false
    var cloudKitReady: Bool = false
    var cloudKitStateString: String = "正在检查状态"
    var endFirstLoading = false
    
    func syncStreamerLiveStates() async throws -> [LiveModel] {
        if self.cloudKitReady {
            //获取是否可以访问google，如果网络环境不允许，则不获取youtube直播相关否则会卡很久
            let roomList = try await CloudSQLManager.searchRecord()
            let canLoadYoutube = await ApiManager.checkInternetConnection()
            for liveModel in roomList {
                if liveModel.liveType == .youtube && canLoadYoutube == false {
//                    needShowToast?("当前网络环境无法获取Youtube房间状态\n本次将会跳过")
                    break
                }
            }
            var fetchedModels: [LiveModel] = []
            var bilibiliModels: [LiveModel] = []
            for liveModel in roomList {
                if liveModel.liveType == .bilibili {
                    bilibiliModels.append(liveModel)
                }else if liveModel.liveType == .youtube && canLoadYoutube == false {
                    continue
                }else {
                    do {
                        print("开始同步房间号\(liveModel.roomId), 主播名字\(liveModel.userName), 平台\(liveModel.liveType), 进度\(fetchedModels.count + 1)/\(roomList.count)")
                        let dataReq = try await ApiManager.fetchLastestLiveInfo(liveModel: liveModel)
                        if liveModel.liveType == .ks {
                            var finalLiveModel = liveModel
                            finalLiveModel.liveState = dataReq.liveState
                            fetchedModels.append(finalLiveModel)
                        }
                        fetchedModels.append(dataReq)
                    } catch {
                        print("房间号\(liveModel.roomId), 主播名字\(liveModel.userName), 平台\(liveModel.liveType), \(error)")
                        var errorModel = liveModel
                        errorModel.liveState = LiveState.unknow.rawValue
                        fetchedModels.append(errorModel)
                    }
                }
            }
            
            if bilibiliModels.count > 0 {
//                needShowToast?("同步除B站主播状态成功, 开始同步B站主播状态,预计时间\(Double(bilibiliModels.count) * 1.5)秒")
            }
            
            for item in bilibiliModels { //B站可能存在风控，触发条件为访问过快或没有Cookie？
                do {
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 等待1.5秒
                    let dataReq = try await ApiManager.fetchLastestLiveInfo(liveModel: item)
                    print("开始同步房间号\(item.roomId), 主播名字\(item.userName), 平台\(item.liveType), 进度\(fetchedModels.count + 1)/\(roomList.count)")
                    fetchedModels.append(dataReq)
                }catch {
                    print("房间号\(item.roomId), 主播名字\(item.userName), 平台\(item.liveType), \(error)")
                }
            }
            let sortedModels = fetchedModels.sorted { firstModel, secondModel in
                switch (firstModel.liveState, secondModel.liveState) {
                case ("1", "1"):
                    return true // 两个都是1，保持原有顺序
                case ("1", _):
                    return true // 第一个是1，应该排在前面
                case (_, "1"):
                    return false // 第二个是1，应该排在前面
                case ("2", "2"):
                    return true // 两个都是2，保持原有顺序
                case ("2", _):
                    return true // 第一个是2，应该排在非1的前面
                case (_, "2"):
                    return false // 第二个是2，应该排在非1的前面
                default:
                    return true // 两个都不是1和2，保持原有顺序
                }
            }
            return sortedModels
        }else {
            return []
        }
    }
    
    func getState() {
        Task {
            self.cloudKitStateString = "正在获取iCloud状态"
            let stateString = await CloudSQLManager.getCloudState()
            self.cloudKitStateString = stateString
            if stateString == "正常" {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.cloudKitReady = true
                }
            }else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.cloudKitReady = false
                }
            }
        }
    }
    
}
