buildscript {
    val kotlinVersion = "1.9.22" // ОБНОВИ ДО 1.9.22
    
    repositories {
        google()
        mavenCentral()
    }
    
    dependencies {
        classpath("com.android.tools.build:gradle:8.1.0") // ИЛИ 8.2.2, но НЕ 7.4.2
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.layout.buildDirectory.set(file("../build"))
subprojects {
    project.layout.buildDirectory.set(file("${rootProject.layout.buildDirectory.get().asFile}/${project.name}"))
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}