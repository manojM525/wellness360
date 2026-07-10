package com.taskmaster.taskmaster;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest
@ActiveProfiles("test")
class TaskmasterApplicationTests {

	@Test
	void contextLoads() {
		// Intentionally empty: a failure here means the Spring context
		// couldn't wire up at all (bad bean config, missing datasource,
		// broken component scan) — the cheapest possible test with the
		// highest signal, and the CI "unit test" stage's first line of defense.
	}

}
