//
//  OutRunV3to4.swift
//
//  OutRun
//  Copyright (C) 2020 Tim Fraedrich <timfraedrich@icloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import CoreStore

enum OutRunV3to4: ORDataModel, ORIntermediateDataModel {
    
    static let identifier = "OutRunV3to4"
    static let schema = CoreStoreSchema(
        modelVersion: OutRunV3to4.identifier,
        entities: [
            Entity<OutRunV3to4.Workout>(OutRunV3to4.Workout.identifier),
            Entity<OutRunV3to4.WorkoutPause>(OutRunV3to4.WorkoutPause.identifier),
            Entity<OutRunV3to4.WorkoutEvent>(OutRunV3to4.WorkoutEvent.identifier),
            Entity<OutRunV3to4.WorkoutRouteDataSample>(OutRunV3to4.WorkoutRouteDataSample.identifier),
            Entity<OutRunV3to4.WorkoutHeartRateDataSample>(OutRunV3to4.WorkoutHeartRateDataSample.identifier),
            Entity<OutRunV3to4.Event>(OutRunV3to4.Event.identifier)
        ],
        versionLock: [
            OutRunV3to4.Workout.identifier: [0x236fcba032b81ba9, 0xa776b92c815cdcc0, 0x123af15289e50cd9, 0x9766946e390e574f],
            OutRunV3to4.WorkoutPause.identifier: [0x89c52b63c97fb5c1, 0xa652377da0a883b8, 0x43cfd39627f2cc09, 0x33ce6792256451a7],
            OutRunV3to4.WorkoutEvent.identifier: [0xc8b4bcf7f34100da, 0x67200344c2f3739d, 0xa56af4887eeceff8, 0xd8b0a9428219090],
            OutRunV3to4.WorkoutRouteDataSample.identifier: [0x8fb3f3add05348dc, 0xaf69cdd28c67537, 0xeda9c05c619958f, 0x62c61c5f0f6a8978],
            OutRunV3to4.WorkoutHeartRateDataSample.identifier: [0x2d847ce2c9e2d59a, 0x93983df8613a51d3, 0x8c53679540e541, 0xbc184a9bacf65f72],
            OutRunV3to4.Event.identifier: [0x8bc19058de8406f1, 0x4c9ab406f7d1eb5c, 0x7c3d5afd97f2c925, 0xd53b84436cc6cdb0]
        ]
    )
    static let mappingProvider: CustomSchemaMappingProvider? = CustomSchemaMappingProvider(
        from: OutRunV3.identifier,
        to: OutRunV3to4.identifier,
        entityMappings: [
            .transformEntity(
                sourceEntity: OutRunV3.Workout.identifier,
                destinationEntity: OutRunV3to4.Workout.identifier,
                transformer: { (sourceObject: CustomSchemaMappingProvider.UnsafeSourceObject, createDestinationObject: () -> CustomSchemaMappingProvider.UnsafeDestinationObject) in
                    let destinationObject = createDestinationObject()
                    destinationObject.enumerateAttributes { (attribute, sourceAttribute) in
                        if let sourceAttribute = sourceAttribute {
                            destinationObject[attribute] = sourceObject[sourceAttribute]
                        }
                    }
                }
            ),
            .insertEntity(destinationEntity: OutRunV3to4.WorkoutPause.identifier),
            .copyEntity(sourceEntity: OutRunV3.WorkoutEvent.identifier, destinationEntity: OutRunV3to4.WorkoutEvent.identifier),
            .copyEntity(sourceEntity: OutRunV3.WorkoutRouteDataSample.identifier, destinationEntity: OutRunV3to4.WorkoutRouteDataSample.identifier),
            .copyEntity(sourceEntity: OutRunV3.WorkoutHeartRateDataSample.identifier, destinationEntity: OutRunV3to4.WorkoutHeartRateDataSample.identifier),
            .copyEntity(sourceEntity: OutRunV3.Event.identifier, destinationEntity: OutRunV3to4.Event.identifier)
        ]
    )
    static let migrationChain: [ORDataModel.Type] = [OutRunV1.self, OutRunV2.self, OutRunV3.self, OutRunV3to4.self]
    static let intermediateMappingActions: ORIntermediateMappingActions = { dataStack in
        
        let transaction = dataStack.beginUnsafe()
        
        if let workouts = try? transaction.fetchAll(From<OutRunV3to4.Workout>()) {
            
            mainloop: for workout in workouts where !workout.workoutEvents.isEmpty {
                
                let workout = transaction.edit(workout)!
                workout.ascend .= 0 // ToDo: NEEDS COMPUTATION
                workout.descend .= 0 // ToDo: NEEDS COMPUTATION
                workout.dayIdentifier .= CustomTimeFormatting.dayIdentifier(forDate: workout.startDate.value)
                
                // handling of events
                var tempEvents = workout.workoutEvents.value
                
                // validation -> pauses are not taken to next version if this fails
                
                // date range
                if tempEvents.contains(where: { (event) -> Bool in
                    event.startDate.value < workout.startDate.value || event.startDate.value > workout.endDate.value
                }) {
                   continue
                }
                
                // starts with pause (manual pause == 0; automatic pause == 1)
                if ![nil, 0, 1].contains(tempEvents.first?.eventType.value) {
                    continue
                }
                
                // shouldnt contain more resume than pause objects
                let pauseCount = tempEvents.filter { (event) -> Bool in [0, 1].contains(event.eventType.value)}.count
                let resumeCount = tempEvents.filter { (event) -> Bool in [2, 3].contains(event.eventType.value)}.count
                if pauseCount < resumeCount {
                    continue
                }
                
                // pause objects can be build from the data
                var pauseData: [(start: Date, end: Date, type: Int)] = []
                for (index, pauseEvent) in tempEvents.enumerated() where [0, 1].contains(pauseEvent.eventType.value) {
                    if let resumeEvent = tempEvents.safeValue(for: index + 1), resumeEvent.eventType.value == pauseEvent.eventType.value + 2 {
                        pauseData.append((start: pauseEvent.startDate.value, end: resumeEvent.startDate.value, type: pauseEvent.eventType.value))
                    } else if index == tempEvents.count - 1 {
                        pauseData.append((start: pauseEvent.startDate.value, end: workout.endDate.value, type: pauseEvent.eventType.value))
                    } else {
                        continue mainloop
                    }
                    
                    // check for overlaps
                    let dataPoint = pauseData.last!
                    let range = dataPoint.start...dataPoint.end
                    
                    for otherDataPoint in pauseData.dropLast() {
                        
                        // check for duplicate
                        if dataPoint == otherDataPoint {
                            continue mainloop
                        }
                        
                        // check for overlap
                        let otherRange = otherDataPoint.start...otherDataPoint.end
                        if range.overlaps(otherRange) {
                            continue mainloop
                        }
                        
                    }
                }
                
                
                
                // now converting raw data to objects and adding them to the workout model
                for dataPoint in pauseData {
                    
                    let pause = transaction.create(Into<OutRunV3to4.WorkoutPause>())
                    pause.uuid .= UUID()
                    pause.startDate .= dataPoint.start
                    pause.endDate .= dataPoint.end
                    pause.pauseType .= dataPoint.type
                    pause.workout .= workout
                    
                }
                
                // pauses done!
                // old workout events for pause or resume events will be deleted in migration automatically
                
                // settings now computable active and pause duration
                
                var pauseDuration: TimeInterval = 0
                pauseData.forEach { (dataPoint) in
                    pauseDuration += dataPoint.start.distance(to: dataPoint.end)
                }
                var activeDuration: TimeInterval = workout.startDate.value.distance(to: workout.endDate.value) - pauseDuration
                
                workout.activeDuration .= activeDuration
                workout.pauseDuration .= pauseDuration
                
            }
            
        } else {
            print("[OutRunV3to4] Failed to fetch workouts")
            return false
        }
        
        if ((try? transaction.commitAndWait()) != nil) {
            return true
        } else {
            print("[OutRunV3to4] Failed to commit transaction in the process of performing intermediate mapping actions")
            return false
        }
        
    }
    
    // MARK: Workout
    class Workout: CoreStoreObject {
        
        static let identifier = "Workout"
        
        let uuid = Value.Optional<UUID>("id")
        let workoutType = Value.Required<Int>("workoutType", initial: -1)
        let distance = Value.Required<Double>("distance", initial: -1)
        let steps = Value.Optional<Int>("steps")
        let startDate = Value.Required<Date>("startDate", initial: .init(timeIntervalSince1970: 0))
        let endDate = Value.Required<Date>("endDate", initial: .init(timeIntervalSince1970: 0))
        let burnedEnergy = Value.Optional<Double>("burnedEnergy")
        let isRace = Value.Required<Bool>("isRace", initial: false)
        let comment = Value.Optional<String>("comment")
        let isUserModified = Value.Required<Bool>("isUserModified", initial: false)
        let healthKitUUID = Value.Optional<UUID>("healthKitID")
        
        // MARK: NOTE: Needs to be set in intermediate migration actions
        let ascend = Value.Required<Double>("ascendingAltitude", initial: 0)
        let descend = Value.Required<Double>("descendingAltitude", initial: 0)
        let activeDuration = Value.Required<Double>("activeDuration", initial: 0)
        let pauseDuration = Value.Required<Double>("pauseDuration", initial: 0)
        let dayIdentifier = Value.Required<String>("dayIdentifier", initial: "")
        
        let heartRates = Relationship.ToManyOrdered<OutRunV3to4.WorkoutHeartRateDataSample>("heartRates", inverse: { $0.workout })
        let routeData = Relationship.ToManyOrdered<OutRunV3to4.WorkoutRouteDataSample>("routeData", inverse: { $0.workout })
        let pauses = Relationship.ToManyOrdered<OutRunV3to4.WorkoutPause>("pauses", inverse: { $0.workout })
        let workoutEvents = Relationship.ToManyOrdered<OutRunV3to4.WorkoutEvent>("workoutEvents", inverse: { $0.workout })
        let events = Relationship.ToManyUnordered<OutRunV3to4.Event>("events", inverse: { $0.workouts })
        
    }
    
    // MARK: WorkoutPause
    class WorkoutPause: CoreStoreObject {
        
        static let identifier = "WorkoutPause"
        
        let uuid = Value.Optional<UUID>("id")
        let startDate = Value.Required<Date>("startDate", initial: .init(timeIntervalSince1970: 0))
        let endDate = Value.Required<Date>("endDate", initial: .init(timeIntervalSince1970: 0))
        let pauseType = Value.Required<Int>("pauseType", initial: 0)
        
        let workout = Relationship.ToOne<OutRunV3to4.Workout>("workout")
        
    }
    
    // MARK: Workout Event
    class WorkoutEvent: CoreStoreObject {
        
        static let identifier = "WorkoutEvent"
        
        let uuid = Value.Optional<UUID>("id")
        let eventType = Value.Required<Int>("eventType", initial: 0)
        let startDate = Value.Required<Date>("startDate", initial: .init(timeIntervalSince1970: 0))
        let endDate =  Value.Required<Date>("endDate", initial: .init(timeIntervalSince1970: 0))
        
        let duration = Value.Required<Double>("duration", initial: 0, isTransient: true, customGetter: { _ in 0})
        
        let workout = Relationship.ToOne<OutRunV3to4.Workout>("workout")
        
    }
    
    // MARK: Route Data Sample
    class WorkoutRouteDataSample: CoreStoreObject {
        
        static let identifier = "WorkoutRouteDataSample"
        
        let uuid = Value.Optional<UUID>("id")
        let timestamp = Value.Required<Date>("timestamp", initial: .init(timeIntervalSince1970: 0))
        let latitude = Value.Required<Double>("latitude", initial: -1)
        let longitude = Value.Required<Double>("longitude", initial: -1)
        let altitude = Value.Required<Double>("altitude", initial: -1)
        let horizontalAccuracy = Value.Required<Double>("horizontalAccuracy", initial: 0)
        let verticalAccuracy = Value.Required<Double>("verticalAccuracy", initial: 0)
        let speed = Value.Required<Double>("speed", initial: -1)
        let direction = Value.Required<Double>("direction", initial: -1)
        
        let workout = Relationship.ToOne<OutRunV3to4.Workout>("workout")
        
    }
    
    // MARK: Workout Heart Rate Data Sample
    class WorkoutHeartRateDataSample: CoreStoreObject {
        
        static let identifier = "WorkoutHeartRateSample"
        
        let uuid = Value.Optional<UUID>("id")
        let heartRate = Value.Required<Double>("heartRate", initial: 0)
        let timestamp = Value.Required<Date>("timestamp", initial: .init(timeIntervalSince1970: 0))
        
        let workout = Relationship.ToOne<OutRunV3to4.Workout>("workout")
        
    }
    
    // MARK: Event
    class Event: CoreStoreObject {
        
        static let identifier = "Event"
        
        let uuid = Value.Optional<UUID>("id")
        let title = Value.Required<String>("eventTitle", initial: "")
        let comment = Value.Optional<String>("comment")
        let startDate = Value.Optional<Date>("startDate", isTransient: true, customGetter: { _ in .init(timeIntervalSince1970: 0)})
        let endDate = Value.Optional<Date>("endDate", isTransient: true, customGetter: { _ in .init(timeIntervalSince1970: 0)})
        
        let workouts = Relationship.ToManyUnordered<OutRunV3to4.Workout>("workouts")
        
    }
    
}
