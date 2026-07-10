package com.taskmaster.taskmaster;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.test.context.ActiveProfiles;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

@DataJpaTest
@ActiveProfiles("test")
class TaskRepositoryTest {

    @Autowired
    private TaskRepository taskRepository;

    @Test
    void savesAndRetrievesATask() {
        Task task = new Task(null, "Write Terraform docs", "Cover the ECS module",
                TaskStatus.TODO, Instant.now(), Instant.now());

        Task saved = taskRepository.save(task);

        assertThat(saved.getId()).isNotNull();
        assertThat(taskRepository.findById(saved.getId()))
                .isPresent()
                .get()
                .extracting(Task::getStatus)
                .isEqualTo(TaskStatus.TODO);
    }
}
