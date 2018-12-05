//
//  CoreDataGenerator.swift
//  slate
//
//  Created by Jason Fieldman on 5/29/18.
//  Copyright © 2018 Jason Fieldman. All rights reserved.
//

import Foundation

private let kStringArgVar: String = "%@"

class CoreDataSwiftGenerator {

    static var entityToSlateClass: [String: String] = [:]
    static var entityToCDClass: [String: String] = [:]
    
    /**
     Master entrance point to the file generation
     */
    static func generateCoreData(
        entities: [CoreDataEntity],
        useClass: Bool,
        classXform: String,
        fileXform: String,
        outputPath: String,
        entityPath: String,
        importModule: String)
    {
        let filePerClass: Bool = fileXform.contains(kStringArgVar)
        var fileAccumulator = generateHeader(filename: fileXform, importModule: importModule)
        
        // First pass create lookup dictionaries
        for entity in entities {
            let className: String = classXform.replacingOccurrences(of: kStringArgVar, with: entity.entityName)
            
            entityToSlateClass[entity.entityName] = className
            entityToCDClass[entity.entityName] = entity.codeClass
        }
        
        for entity in entities {
            let className: String = classXform.replacingOccurrences(of: kStringArgVar, with: entity.entityName)
            let filename: String = fileXform.replacingOccurrences(of: kStringArgVar, with: entity.entityName)
            
            // Start a new file accumulator if uses per-class file
            if filePerClass {
                fileAccumulator = generateHeader(filename: filename, importModule: importModule)
            }
            
            fileAccumulator += entityCode(entity: entity, useClass: useClass, className: className)
            
            // Write to file if necessary
            if filePerClass {
                let filepath = (outputPath as NSString).appendingPathComponent("\(filename).swift")
                try! fileAccumulator.write(toFile: filepath, atomically: true, encoding: String.Encoding.utf8)
            }
        }

        // Output Core Data entity files if necessary
        if entityPath.count > 0 {
            for entity in entities {
                let filename = "\(entity.codeClass).swift"
                let properties = generateCoreDataEntityProperties(entity: entity)
                let file = template_CD_Entity.replacingWithMap(
                    ["FILENAME": filename,
                     "COMMAND": _embedCommand ? "\n// This file was generated by slate using:\n// \(commandline)" : "",
                     "CDENTITYCLASS": entity.codeClass,
                     "CDENTITYNAME": entity.entityName,
                     "PROPERTIES": properties]
                )

                let filepath = (entityPath as NSString).appendingPathComponent(filename)
                try! file.write(toFile: filepath, atomically: true, encoding: String.Encoding.utf8)
            }
        }
        
        // Output single file if necessary
        if !filePerClass {
            let filepath = (outputPath as NSString).appendingPathComponent("\(fileXform).swift")
            try! fileAccumulator.write(toFile: filepath, atomically: true, encoding: String.Encoding.utf8)
        }
    }

    static func generateHeader(filename: String, importModule: String) -> String {
        return template_CD_Swift_fileheader.replacingWithMap(
            ["FILENAME": filename,
             "COMMAND": _embedCommand ? "\n// This file was generated by slate using:\n// \(commandline)" : "",
             "EXTRAIMPORT": (importModule != "") ? "\nimport \(importModule)" : "" ]
        )
    }
    
    static var commandline: String {
        return CommandLine.arguments.joined(separator: " ")
    }
    
    static func entityCode(
        entity: CoreDataEntity,
        useClass: Bool,
        className: String
    ) -> String {
        
        let convertible = template_CD_Swift_SlateObjectConvertible.replacingWithMap(
            ["COREDATACLASS": entity.codeClass,
             "SLATECLASS": className]
        )
        
        let moExtension = template_CD_Swift_ManagedObjectExtension.replacingWithMap(
            ["COREDATACLASS": entity.codeClass,
             "COREDATAENTITYNAME": entity.entityName]
        )

        let classImpl = generateClassImpl(entity: entity, useClass: useClass, className: className)
        let relations = generateRelationships(entity: entity, useClass: useClass, className: className)
        let equatable = generateEquatable(entity: entity, className: className)
        
        return "\(convertible)\(moExtension)\(classImpl)\(relations)\(equatable)"
    }

    static func generateClassImpl(entity: CoreDataEntity, useClass: Bool, className: String) -> String {
        var declarations: String = ""
        var assignments: String = ""
        
        for attr in entity.attributes {
            declarations += template_CD_Swift_AttrDeclaration.replacingWithMap(
                ["ATTR": attr.name,
                 "TYPE": attr.type.immType,
                 "OPTIONAL": attr.optional ? "?" : ""])

            let amConvertingOptToScalar = !attr.optional && !attr.useScalar && attr.type.needsOptConvIfNotScalar
            let useForce = (!attr.optional && attr.type.codeGenForceOptional) || amConvertingOptToScalar
            let str = useForce ? template_CD_Swift_AttrForceAssignment : template_CD_Swift_AttrAssignment
            var conv = ""
            if let sconv = attr.type.swiftValueConversion, !attr.useScalar {
                conv = ((attr.optional || useForce) ? "?" : "") + sconv
            } else if _useInt && attr.type.isInt {
                conv = ((attr.optional  && !attr.useScalar) ? "?" : "") + ".slate_asInt"
            }
            assignments += str.replacingWithMap(
                ["ATTR": attr.name,
                 "TYPE": attr.type.immType,
                 "CONV": conv,
                ])
        }

        let substruct = entity.substructs.reduce("") {
            return $0 + generateSubstructImpl(substruct: $1, baseEntityClass: entity.codeClass)
        }

        for substruct in entity.substructs {
            let substructType = className + "." + substruct.structName
            declarations += template_CD_Swift_AttrDeclaration.replacingWithMap(
                ["ATTR": substruct.varName,
                 "TYPE": substructType,
                 "OPTIONAL": substruct.optional ? "?" : ""])

            let str = substruct.optional ? template_CD_Swift_AttrAssignmentForOptSubstruct : template_CD_Swift_AttrAssignmentForSubstruct
            assignments += str.replacingWithMap(
                ["ATTR": substruct.varName,
                 "TYPE": substructType]
            )
        }
        
        return template_CD_Swift_SlateClassImpl.replacingWithMap(
            ["OBJTYPE": useClass ? "class" : "struct",
             "SLATECLASS": className,
             "COREDATACLASS": entity.codeClass,
             "ATTRASSIGNMENT": assignments,
             "ATTRDECLARATIONS": declarations,
             "SUBSTRUCTS": substruct]
        )
    }

    static func generateSubstructImpl(substruct: CoreDataSubstruct, baseEntityClass: String) -> String {
        var declarations: String = ""
        var assignments: String = ""

        for attr in substruct.attributes {
            let isOptionalForStruct: Bool = {
                if let optInStruct = attr.userdata["optInStruct"] {
                    return optInStruct == "true"
                }
                return attr.optional
            }()

            declarations += template_CD_Swift_SubstructAttrDeclaration.replacingWithMap(
                ["ATTR": attr.name,
                 "TYPE": attr.type.immType,
                 "OPTIONAL": isOptionalForStruct ? "?" : ""])

            let useForce = !isOptionalForStruct && (attr.type.codeGenForceOptional || attr.optional)
            let str = useForce ? template_CD_Swift_SubstructAttrForceAssignment : template_CD_Swift_SubstructAttrAssignment
            var conv = ""
            if let sconv = attr.type.swiftValueConversion, !attr.useScalar {
                conv = ((attr.optional) ? "?" : "") + sconv
            } else if _useInt && attr.type.isInt {
                conv = ((attr.optional && !attr.useScalar) ? "?" : "") + ".slate_asInt"
            }

            let def: String = attr.userdata["default"] ?? ""
            if useForce && def.isEmpty {
                print("substruct property \(baseEntityClass).\(substruct.varName + "_" + attr.name) is forced non-optional but does not have a default userInfo key")
            }

            assignments += str.replacingWithMap(
                ["ATTR": attr.name,
                 "STRNAME": substruct.varName,
                 "TYPE": attr.type.immType,
                 "CONV": conv,
                 "DEF": def,
                 ])
        }

        return template_CD_Swift_SlateSubstructImpl.replacingWithMap(
            ["SLATESUBSTRUCT": substruct.structName,
             "COREDATACLASS": baseEntityClass,
             "ATTRASSIGNMENT": assignments,
             "ATTRDECLARATIONS": declarations]
        )
    }
    
    static func generateRelationships(entity: CoreDataEntity, useClass: Bool, className: String) -> String {
        var relationships: String = ""
        for relationship in entity.relationships {
            if relationship.toMany {
                relationships += template_CD_Swift_SlateRelationshipToMany.replacingWithMap(
                    ["RELATIONSHIPNAME": relationship.name,
                     "TARGETSLATECLASS": entityToSlateClass[relationship.destinationEntityName]!,
                     "COREDATACLASS": entity.codeClass]
                )
            } else {
                relationships += template_CD_Swift_SlateRelationshipToOne.replacingWithMap(
                    ["RELATIONSHIPNAME": relationship.name,
                     "TARGETSLATECLASS": entityToSlateClass[relationship.destinationEntityName]!,
                     "COREDATACLASS": entity.codeClass,
                     "OPTIONAL": relationship.optional ? "?" : "",
                     "NONOPTIONAL": relationship.optional ? "" : "!"]
                )
            }
        }
        
        return template_CD_Swift_SlateRelationshipResolver.replacingWithMap(
            ["OBJQUAL": useClass ? ": " : " == ",
             "SLATECLASS": className,
             "RELATIONSHIPS": relationships]
        )
    }
    
    static func generateEquatable(entity: CoreDataEntity, className: String) -> String {
        var attrs = ""
        for attr in entity.attributes {
            // No support for transformable right now?
            if attr.type == .transformable {
                return ""
            }
            
            attrs += " &&\n               (lhs.\(attr.name) == rhs.\(attr.name))"
        }
        
        return template_CD_Swift_SlateEquatable.replacingWithMap(
            ["SLATECLASS": className,
             "ATTRS": attrs]
        )
    }



    // ----- Core Data Entities -----

    static func generateCoreDataEntityProperties(entity: CoreDataEntity) -> String {
        var properties = ""
        for attribute in entity.attributes {
            properties += template_CD_Entity_Property.replacingWithMap(
                ["VARNAME": attribute.name,
                 "OPTIONAL": ((attribute.optional || attribute.type.codeGenForceOptional) && !attribute.useScalar) ? "?" : "",
                 "TYPE": attribute.type.swiftManagedType(scalar: attribute.useScalar)
                ]
            )
        }
        for substruct in entity.substructs {
            properties += "\n"

            if substruct.optional {
                properties += template_CD_Entity_Property.replacingWithMap(
                    ["VARNAME": substruct.varName + "_has",
                     "OPTIONAL": "",
                     "TYPE": "Bool"
                    ]
                )
            }

            for attribute in substruct.attributes {
                properties += template_CD_Entity_Property.replacingWithMap(
                    ["VARNAME": substruct.varName + "_" + attribute.name,
                     "OPTIONAL": (attribute.optional && !attribute.useScalar) ? "?" : "",
                     "TYPE": attribute.type.swiftManagedType(scalar: attribute.useScalar)
                    ]
                )
            }
        }
        for relationship in entity.relationships {
            properties += "\n"

            var type = "NSSet"
            if relationship.ordered { type = "NSOrderedSet" }
            if !relationship.toMany {
                type = entityToCDClass[relationship.destinationEntityName] ?? "---"
            }

            properties += template_CD_Entity_Property.replacingWithMap(
                ["VARNAME": relationship.name,
                 "OPTIONAL": (relationship.optional || relationship.toMany) ? "?" : "",
                 "TYPE": type
                ]
            )
        }
        return properties
    }
}
