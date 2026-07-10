package com.taskmaster.taskmaster;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.rest.core.annotation.RepositoryRestResource;

// Extending JpaRepository is what Spring Data REST hooks into: it auto-exposes
// GET/POST/PUT/PATCH/DELETE on /tasks and /tasks/{id} as HAL+JSON, with
// pagination and sorting, without a hand-written controller layer.
// @RepositoryRestResource just gives the collection a clean, explicit path
// rather than relying on the pluralized-class-name default.
@RepositoryRestResource(path = "tasks", collectionResourceRel = "tasks")
public interface TaskRepository extends JpaRepository<Task, Long> {
}
